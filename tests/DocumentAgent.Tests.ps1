BeforeAll {
  Import-Module "$PSScriptRoot/../DocumentAgent/DocumentAgent.psd1" -Force
  $global:DaRows = @(
    [pscustomobject]@{ document_id = 11; key = 'A'; type = 'BOL'; stamp = '2026-01-01T10:00:00'; file_name = 'Abol.pdf' }
    [pscustomobject]@{ document_id = 12; key = 'A'; type = 'FB'; stamp = '2026-01-01T10:05:00'; file_name = 'Afb.pdf' }
    [pscustomobject]@{ document_id = 21; key = 'B'; type = 'BOL'; stamp = '2026-01-01T11:00:00'; file_name = 'Bbol.pdf' }
    [pscustomobject]@{ document_id = 31; key = 'C'; type = 'BOL'; stamp = '2026-01-01T09:00:00'; file_name = 'Cbol.pdf' }
    [pscustomobject]@{ document_id = 32; key = 'C'; type = 'BOL'; stamp = '2026-01-01T12:00:00'; file_name = 'Cbol.pdf' }
    [pscustomobject]@{ document_id = 33; key = 'C'; type = 'FB'; stamp = '2026-01-01T09:30:00'; file_name = 'Cfb.pdf' }
  )
  $global:DaJob = Join-Path $TestDrive 'job'
  New-Item -ItemType Directory $DaJob | Out-Null
  'param([hashtable] $Options) $global:DaRows' | Set-Content "$DaJob/rows.ps1"
  function Set-DaSettings([hashtable]$Extra = @{}) {
    $settings = @{
      keepdays = 30; purgefiles = '*.log'
      items = @{ adapter = "$DaJob/rows.ps1"; args = @{}; key = 'key'; type = 'type'; order = 'stamp'; require = @('BOL', 'FB') }
      documents = @{ adapter = 'ships'; args = @{ BaseUrl = 'https://portal.example/'; Username = 'reader'; Password = 'env:DA_TEST_PASSWORD' } }
      delivery = @{ adapter = 'email'; args = @{ mail = @{ from = 'from@example.test'; to = @('to@example.test'); subject = 'Paperwork for {0}'; body = 'Attached: {0}' }; msgraph = @{ client_secret = 'env:DA_TEST_SECRET' }; contentType = 'application/pdf' } }
    }
    foreach ($key in $Extra.Keys) { $settings[$key] = $Extra[$key] }
    $settings | ConvertTo-Json -Depth 8 | Set-Content "$DaJob/settings.json"
  }
  $env:DA_TEST_PASSWORD = 'from-env-password'; $env:DA_TEST_SECRET = 'from-env-secret'
  function Get-DaLog { Get-Content (Join-Path $DaJob ('{0:yyyyMMdd}.log' -f (Get-Date))) | ForEach-Object { ($_ -split "`t")[-1] } }
}

Describe 'a document run' {
  BeforeEach {
    Remove-Item "$DaJob/sent", "$DaJob/out", "$DaJob/*.log" -Recurse -Force -ErrorAction Ignore
    Set-Location $TestDrive
    $global:DaSent = [Collections.Generic.List[object]]::new()
    Mock New-ShipsSession -ModuleName DocumentAgent { [pscustomobject]@{ BaseUrl = $BaseUrl } }
    Mock Get-ShipsDocument -ModuleName DocumentAgent { ,([Text.Encoding]::ASCII.GetBytes("%PDF-$DocumentId")) }
    Mock Send-FilesViaEmail -ModuleName DocumentAgent {
      $global:DaSent.Add(@{ files = @($Files | Split-Path -Leaf); present = @($Files | Test-Path); to = @($Cfg.mail.to); subject = $Cfg.mail.subject; body = $Cfg.mail.body; type = $ContentType; secret = $Cfg.msgraph.client_secret })
    }
  }
  It 'delivers every complete group by default, newest scan of each type, one email each, with a receipt' {
    Set-DaSettings
    Invoke-DocumentAgent "$DaJob/settings.json"
    $global:DaSent.Count | Should -Be 2
    $global:DaSent[0].subject | Should -Be 'Paperwork for A'
    $global:DaSent[0].files | Should -Be @('Abol.pdf', 'Afb.pdf')
    $global:DaSent[0].present | Should -Be @($true, $true)
    $global:DaSent[0].body | Should -Be 'Attached: Abol.pdf, Afb.pdf'
    $global:DaSent[0].type | Should -Be 'application/pdf'
    Should -Invoke Get-ShipsDocument -ModuleName DocumentAgent -Times 1 -Exactly -ParameterFilter { $DocumentId -eq 32 }
    Should -Invoke Get-ShipsDocument -ModuleName DocumentAgent -Times 0 -ParameterFilter { $DocumentId -eq 31 }
    Should -Invoke New-ShipsSession -ModuleName DocumentAgent -Times 1 -Exactly
    $receipt = Get-Content "$DaJob/sent/C.json" -Raw | ConvertFrom-Json
    $receipt.documents.document_id | Should -Be @(32, 33)
    $receipt.delivery.to | Should -Be 'to@example.test'
    Test-Path "$DaJob/sent/B.json" | Should -BeFalse
    Get-ChildItem "$DaJob/out" -Filter *.pdf | Should -BeNullOrEmpty
    $log = Get-DaLog
    $log | Should -Contain 'Waiting: B is missing FB'
    $log | Should -Contain 'Sent   : A (Abol.pdf, Afb.pdf) -> to@example.test'
  }
  It 'works in the settings file folder wherever it is called from' {
    Set-DaSettings
    Invoke-DocumentAgent "$DaJob/settings.json"
    Test-Path (Join-Path $DaJob ('{0:yyyyMMdd}.log' -f (Get-Date))) | Should -BeTrue
    Test-Path "$DaJob/sent/A.json" | Should -BeTrue
    Test-Path "$TestDrive/sent" | Should -BeFalse
    Get-ChildItem $TestDrive -Filter *.log | Should -BeNullOrEmpty
  }
  It 'dry_run names the ready groups, fetches and sends nothing' {
    Set-DaSettings @{ dry_run = $true }
    Invoke-DocumentAgent "$DaJob/settings.json"
    Get-DaLog | Should -Contain 'Dry run, not sending: A, C'
    Should -Invoke Get-ShipsDocument -ModuleName DocumentAgent -Times 0
    Should -Invoke Send-FilesViaEmail -ModuleName DocumentAgent -Times 0
    Test-Path "$DaJob/sent" | Should -BeFalse
  }
  It 'max_sends caps a run and leaves the rest for the next one' {
    Set-DaSettings @{ max_sends = 1 }
    Invoke-DocumentAgent "$DaJob/settings.json"
    $global:DaSent.Count | Should -Be 1
    Get-DaLog | Should -Contain 'Cap    : 1 of 2 this run, the rest go next run'
    Test-Path "$DaJob/sent/C.json" | Should -BeFalse
  }
  It 'never delivers a group twice, and nothing new is the idle marker' {
    Set-DaSettings
    New-Item -ItemType Directory "$DaJob/sent" -Force | Out-Null
    '{}' | Set-Content "$DaJob/sent/A.json"
    '{}' | Set-Content "$DaJob/sent/C.json"
    Invoke-DocumentAgent "$DaJob/settings.json"
    Get-DaLog | Should -Contain 'No data available'
    Should -Invoke Send-FilesViaEmail -ModuleName DocumentAgent -Times 0
  }
  It 'reads env: values from the environment and keeps them out of the file' {
    Set-DaSettings
    Invoke-DocumentAgent "$DaJob/settings.json"
    Should -Invoke New-ShipsSession -ModuleName DocumentAgent -Times 1 -Exactly -ParameterFilter { $Credential.GetNetworkCredential().Password -eq 'from-env-password' }
    $global:DaSent[0].secret | Should -Be 'from-env-secret'
    Get-Content "$DaJob/settings.json" -Raw | Should -Not -Match 'from-env'
  }
  It 'delivers the groups behind a failed one, then fails the run naming it' {
    Set-DaSettings
    Mock Get-ShipsDocument -ModuleName DocumentAgent { if ($DocumentId -eq 11) { throw 'portal error for 11' }; ,([Text.Encoding]::ASCII.GetBytes('%PDF-')) }
    { Invoke-DocumentAgent "$DaJob/settings.json" } | Should -Throw '*1 group(s) failed*A*'
    $global:DaSent.Count | Should -Be 1
    $global:DaSent[0].subject | Should -Be 'Paperwork for C'
    Test-Path "$DaJob/sent/A.json" | Should -BeFalse
    Test-Path "$DaJob/sent/C.json" | Should -BeTrue
    Get-DaLog | Should -Contain 'Failed : A: portal error for 11'
  }
  It 'keeps no receipt when the delivery itself fails' {
    Set-DaSettings
    Mock Send-FilesViaEmail -ModuleName DocumentAgent { if ($Cfg.mail.subject -match 'C$') { throw 'graph timeout' } }
    { Invoke-DocumentAgent "$DaJob/settings.json" } | Should -Throw '*C*'
    Test-Path "$DaJob/sent/A.json" | Should -BeTrue
    Test-Path "$DaJob/sent/C.json" | Should -BeFalse
    Get-ChildItem "$DaJob/out" -Filter *.pdf | Should -BeNullOrEmpty
  }
  It 'hands a delivery that asks for -Documents the rows, and fetches a document shared by two groups once' {
    $global:DaRows = @(
      [pscustomobject]@{ document_id = 41; key = 'P-1'; file_name = 'same.pdf'; line = 1 }
      [pscustomobject]@{ document_id = 41; key = 'P-2'; file_name = 'same.pdf'; line = 2 }
    )
    $delivery = "$DaJob/rows-delivery.ps1"
    @'
param([string] $Key, [string[]] $Files, [hashtable] $Options, [object[]] $Documents)
$global:DaSent.Add(@{ key = $Key; items = @($Documents.line); present = @($Files | Test-Path) })
@{ status = 'ok' }
'@ | Set-Content $delivery
    Set-DaSettings @{ items = @{ adapter = "$DaJob/rows.ps1"; args = @{}; key = 'key' }; delivery = @{ adapter = $delivery; args = @{} } }
    Invoke-DocumentAgent "$DaJob/settings.json"
    $global:DaSent.Count | Should -Be 2
    $global:DaSent[0].items | Should -Be @(1)
    $global:DaSent[1].items | Should -Be @(2)
    $global:DaSent[1].present | Should -Be @($true)
    Should -Invoke Get-ShipsDocument -ModuleName DocumentAgent -Times 1 -Exactly
    (Get-Content "$DaJob/sent/P-2.json" -Raw | ConvertFrom-Json).delivery.status | Should -Be 'ok'
    Get-ChildItem "$DaJob/out" -Recurse -Filter *.pdf | Should -BeNullOrEmpty
  }
}

Describe 'built-in sql items' {
  It 'passes arguments to Invoke-Sqlcmd and returns plain objects with nulls for DBNull' {
    $table = [Data.DataTable]::new()
    [void]$table.Columns.Add('document_id', [long]); [void]$table.Columns.Add('file_name', [string])
    [void]$table.Rows.Add(7, 'x.pdf'); [void]$table.Rows.Add(8, [DBNull]::Value)
    Mock Import-Module -ModuleName DocumentAgent {}
    Mock Invoke-Sqlcmd -ModuleName DocumentAgent { $table.Rows }
    $rows = @(& (Get-Module DocumentAgent) { & (Resolve-Adapter 'items' 'sql') -Options @{ InputFile = 'q.sql'; ConnectionString = 'x' } })
    $rows.Count | Should -Be 2
    $rows[0].document_id | Should -Be 7
    $rows[1].file_name | Should -BeNullOrEmpty
    $rows[0] | Should -BeOfType [pscustomobject]
    Should -Invoke Invoke-Sqlcmd -ModuleName DocumentAgent -Times 1 -Exactly -ParameterFilter { $InputFile -eq 'q.sql' -and $OutputAs -eq 'DataRows' }
  }
}
