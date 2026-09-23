# DocumentAgent: a DataAgent variant that delivers documents, one group at a time, once.

# the whole job: settings in, one run of DataAgent in the settings file's folder
function Invoke-DocumentAgent {
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][string]$Settings)
  $path = (Resolve-Path -LiteralPath $Settings).Path
  $config = New-DocumentAgentConfig $path
  $config.directory = Split-Path $path
  Invoke-DataAgent $config
}

# the DataAgent config for a document run, from a settings.json path or the settings as a hashtable.
# like any feed it delivers everything ready; "dry_run" and "max_sends" in the settings are for testing.
function New-DocumentAgentConfig {
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)]$Settings)
  if ($Settings -is [string]) { $Settings = Get-Content -LiteralPath $Settings -Raw | ConvertFrom-Json -AsHashtable }
  $Settings = Resolve-EnvValue $Settings
  $adapters = Join-Path $PSScriptRoot 'adapters'
  $receipts = if ($Settings.receipts) { [string]$Settings.receipts } else { 'sent' }
  $apply = -not $Settings.dry_run
  $config = @{
    src = @{ adapter = Join-Path $adapters 'select.ps1'; args = @{ Items = $Settings.items; Receipts = $receipts; MaxSends = [int]$Settings.max_sends } }
    fmt = @{ adapter = Join-Path $adapters 'fetch.ps1'; args = @{ Path = 'out/documents.json'; Documents = $Settings.documents; Apply = $apply } }
    dst = if ($apply) {
      @{ adapter = Join-Path $adapters 'deliver.ps1'; args = @{ Delivery = $Settings.delivery; Receipts = $receipts } }
    } else {
      @{ adapter = Join-Path $adapters 'skip.ps1'; args = @{} }
    }
  }
  foreach ($name in 'keepdays', 'purgefiles') { if ($Settings.ContainsKey($name)) { $config[$name] = $Settings[$name] } }
  $config
}

# "env:NAME" anywhere in the settings is read from that environment variable, so secrets stay out of the file
function Resolve-EnvValue($Value) {
  if ($Value -is [string]) {
    if ($Value -match '^env:(.+)$') { return [Environment]::GetEnvironmentVariable($Matches[1]) }
    return $Value
  }
  if ($Value -is [System.Collections.IDictionary]) {
    $copy = @{}
    foreach ($key in $Value.Keys) { $copy[$key] = Resolve-EnvValue $Value[$key] }
    return $copy
  }
  if ($Value -is [System.Collections.IList]) { return , @(foreach ($item in $Value) { Resolve-EnvValue $item }) }
  $Value
}

# l returns its line; a source must keep its output stream for records, so the log line goes to the host
function Write-Log([string]$Message) { l $Message | Write-Host }

function Resolve-Adapter([string]$Role, [string]$Name) {
  if ($Name -like '*.ps1') { return $Name }
  Join-Path $PSScriptRoot "$Role/$Name.ps1"
}

# source: rows -> groups that are complete, not yet delivered, within the send cap
function Select-DocumentGroup {
  param([hashtable]$Options)
  $items = $Options.Items
  $rows = @(& (Resolve-Adapter 'items' $items.adapter) -Options $items.args)
  $key = $items.key; $type = $items.type; $order = $items.order
  $groups = @($rows | Group-Object -CaseSensitive { [string]$_.$key } | ForEach-Object {
    $documents = @($_.Group)
    if ($type) {
      # newest scan of each type wins
      $documents = @($documents | Sort-Object { [string]$_.$order }, { [long]$_.document_id } -Descending |
        Group-Object -CaseSensitive { [string]$_.$type } | ForEach-Object { $_.Group[0] } | Sort-Object { [string]$_.$type })
    }
    $missing = @($items.require | Where-Object { $_ -and $_ -cnotin @($documents | ForEach-Object { [string]$_.$type }) })
    [pscustomobject]@{ key = $_.Name; documents = $documents; missing = $missing }
  } | Sort-Object key)
  $delivered = @($groups | Where-Object { Test-Path -LiteralPath (Join-Path $Options.Receipts "$($_.key).json") })
  $waiting = @($groups | Where-Object { $_.missing.Count -and $_ -notin $delivered })
  $ready = @($groups | Where-Object { -not $_.missing.Count -and $_ -notin $delivered })
  Write-Log "Groups : $($groups.Count) found, $($delivered.Count) already delivered, $($waiting.Count) waiting, $($ready.Count) ready"
  foreach ($group in $waiting) { Write-Log "Waiting: $($group.key) is missing $($group.missing -join ', ')" }
  if ($Options.MaxSends -gt 0 -and $ready.Count -gt $Options.MaxSends) {
    Write-Log "Cap    : $($Options.MaxSends) of $($ready.Count) this run, the rest go next run"
    $ready = @($ready | Select-Object -First $Options.MaxSends)
  }
  $ready
}

# format: fetch each group's files into out/, write the manifest the destination reads
function Save-GroupDocument {
  param($Data, [hashtable]$Options)
  $directory = Split-Path $Options.Path
  $directory = (New-Item -ItemType Directory -Force $directory).FullName
  $source = $Options.Documents
  $context = @{}
  $manifest = @(foreach ($group in @($Data)) {
    $entry = [ordered]@{ key = $group.key; documents = @($group.documents); files = @(); error = $null }
    if ($Options.Apply) {
      try {
        # a folder per group: two groups can carry the same document under the same name
        $folder = (New-Item -ItemType Directory -Force (Join-Path $directory ([string]$group.key))).FullName
        $entry.files = @(foreach ($document in $group.documents) {
          [byte[]]$bytes = & (Resolve-Adapter 'documents' $source.adapter) -Document $document -Options $source.args -Context $context
          $path = Join-Path $folder ([string]$document.file_name)
          Set-Content -LiteralPath $path -Value $bytes -AsByteStream
          $path
        })
      } catch {
        $entry.error = $_.Exception.Message
      }
    }
    $entry
  })
  ConvertTo-Json -InputObject $manifest -Depth 6 | Set-Content -LiteralPath $Options.Path
}

# destination: deliver each fetched group once; a failed group waits for the next run
function Send-DocumentGroup {
  param([string]$Path, [hashtable]$Options)
  $delivery = $Options.Delivery
  $null = New-Item -ItemType Directory -Force $Options.Receipts
  $failed = [Collections.Generic.List[string]]::new()
  $adapter = Resolve-Adapter 'delivery' $delivery.adapter
  # an adapter that declares -Documents also gets the group's rows
  $withRows = (Get-Command $adapter).Parameters.ContainsKey('Documents')
  foreach ($group in @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)) {
    $files = @($group.files)
    $names = @($files | Split-Path -Leaf) -join ', '
    try {
      if ($group.error) { throw $group.error }
      $arguments = @{ Key = $group.key; Files = $files; Options = $delivery.args }
      if ($withRows) { $arguments.Documents = @($group.documents) }
      $result = & $adapter @arguments
    } catch {
      Write-Log "Failed : $($group.key): $($_.Exception.Message)"
      $failed.Add($group.key)
      continue
    } finally {
      if ($files) { Remove-Item -LiteralPath (Split-Path $files[0]) -Recurse -Force -ErrorAction Ignore }
    }
    [ordered]@{ key = $group.key; delivered_at = [datetime]::UtcNow.ToString('o'); delivery = $result; documents = @($group.documents) } |
      ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Options.Receipts "$($group.key).json")
    Write-Log "Sent   : $($group.key) ($names)$(if ($result.to) { " -> $(@($result.to) -join ', ')" })"
  }
  if ($failed.Count) { throw "$($failed.Count) group(s) failed and will retry next run: $($failed -join ', ')" }
}

Export-ModuleMember -Function Invoke-DocumentAgent, New-DocumentAgentConfig
