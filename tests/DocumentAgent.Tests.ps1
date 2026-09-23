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
  'param([hashtable] $Options) $global:DaRows' | Set-Content "$TestDrive/rows.ps1"
  @{
    keepdays = 30; purgefiles = '*.log'
    items = @{ adapter = "$TestDrive/rows.ps1"; args = @{}; key = 'key'; type = 'type'; order = 'stamp'; require = @('BOL', 'FB') }
    documents = @{ adapter = 'ships'; args = @{ BaseUrl = 'https://portal.example/'; Username = 'reader'; Password = 'env:DA_TEST_PASSWORD' } }
    delivery = @{ adapter = 'email'; args = @{ mail = @{ from = 'from@example.test'; to = @('to@example.test'); subject = 'Paperwork for {0}'; body = 'Attached: {0}' }; msgraph = @{ client_secret = 'env:DA_TEST_SECRET' }; contentType = 'application/pdf' } }
  } | ConvertTo-Json -Depth 8 | Set-Content "$TestDrive/settings.json"
  @'
param([switch]$Apply, [int]$MaxSends, [string]$To)
Invoke-DataAgent (New-DocumentAgentConfig "$PSScriptRoot/settings.json" @PSBoundParameters)
'@ | Set-Content "$TestDrive/job.ps1"
  $env:DA_TEST_PASSWORD = 'from-env-password'; $env:DA_TEST_SECRET = 'from-env-secret'
  function Get-DaLog { Get-Content (Join-Path $TestDrive ('{0:yyyyMMdd}.log' -f (Get-Date))) | ForEach-Object { ($_ -split "`t")[-1] } }
}

Describe 'a document run through DataAgent' {
  BeforeEach {
    Remove-Item "$TestDrive/sent", "$TestDrive/out", "$TestDrive/*.log" -Recurse -Force -ErrorAction Ignore
    $global:DaSent = [Collections.Generic.List[object]]::new()
    Mock New-ShipsSession -ModuleName DocumentAgent { [pscustomobject]@{ BaseUrl = $BaseUrl } }
    Mock Get-ShipsDocument -ModuleName DocumentAgent { ,([Text.Encoding]::ASCII.GetBytes("%PDF-$DocumentId")) }
    Mock Send-FilesViaEmail -ModuleName DocumentAgent {
      $global:DaSent.Add(@{ files = @($Files | Split-Path -Leaf); present = @($Files | Test-Path); to = @($Cfg.mail.to); subject = $Cfg.mail.subject; body = $Cfg.mail.body; type = $ContentType; secret = $Cfg.msgraph.client_secret })
    }
  }
  It 'dry run names the ready groups and the waiting one, fetches and sends nothing' {
    & "$TestDrive/job.ps1"
    $log = Get-DaLog
    $log | Should -Contain 'Groups : 3 found, 0 already delivered, 1 waiting, 2 ready'
    $log | Should -Contain 'Waiting: B is missing FB'
    $log | Should -Contain 'Cap    : 1 of 2 this run, the rest go next run'
    $log | Should -Contain 'Dry run, not sending: A'
    $log | Should -Contain 'End'
    Should -Invoke Get-ShipsDocument -ModuleName DocumentAgent -Times 0
    Should -Invoke Send-FilesViaEmail -ModuleName DocumentAgent -Times 0
    Test-Path "$TestDrive/sent" | Should -BeFalse
  }
  It 'delivers one email per complete group with the newest scan of each type, and keeps a receipt' {
    & "$TestDrive/job.ps1" -Apply -MaxSends 0
    $global:DaSent.Count | Should -Be 2
    $global:DaSent[0].subject | Should -Be 'Paperwork for A'
    $global:DaSent[0].files | Should -Be @('Abol.pdf', 'Afb.pdf')
    $global:DaSent[0].present | Should -Be @($true, $true)
    $global:DaSent[0].body | Should -Be 'Attached: Abol.pdf, Afb.pdf'
    $global:DaSent[0].type | Should -Be 'application/pdf'
    Should -Invoke Get-ShipsDocument -ModuleName DocumentAgent -Times 1 -Exactly -ParameterFilter { $DocumentId -eq 32 }
    Should -Invoke Get-ShipsDocument -ModuleName DocumentAgent -Times 0 -ParameterFilter { $DocumentId -eq 31 }
    Should -Invoke New-ShipsSession -ModuleName DocumentAgent -Times 1 -Exactly
    $receipt = Get-Content "$TestDrive/sent/C.json" -Raw | ConvertFrom-Json
    $receipt.documents.document_id | Should -Be @(32, 33)
    $receipt.delivery.to | Should -Be 'to@example.test'
    Test-Path "$TestDrive/sent/B.json" | Should -BeFalse
    Get-ChildItem "$TestDrive/out" -Filter *.pdf | Should -BeNullOrEmpty
    Get-DaLog | Should -Contain 'Sent   : A (Abol.pdf, Afb.pdf) -> to@example.test'
  }
  It 'never delivers a group twice, and an hour with nothing new is the idle marker' {
    New-Item -ItemType Directory "$TestDrive/sent" -Force | Out-Null
    '{}' | Set-Content "$TestDrive/sent/A.json"
    '{}' | Set-Content "$TestDrive/sent/C.json"
    & "$TestDrive/job.ps1" -Apply
    Get-DaLog | Should -Contain 'No data available'
    Should -Invoke Send-FilesViaEmail -ModuleName DocumentAgent -Times 0
  }
  It 'caps a run and leaves the rest for the next one' {
    & "$TestDrive/job.ps1" -Apply -MaxSends 1
    $global:DaSent.Count | Should -Be 1
    Get-DaLog | Should -Contain 'Cap    : 1 of 2 this run, the rest go next run'
    Test-Path "$TestDrive/sent/C.json" | Should -BeFalse
  }
  It 'sends one group by default when no cap is given' {
    & "$TestDrive/job.ps1" -Apply
    $global:DaSent.Count | Should -Be 1
    Get-DaLog | Should -Contain 'Cap    : 1 of 2 this run, the rest go next run'
  }
  It 'reads env: values from the environment for the portal login and the mail secret' {
    & "$TestDrive/job.ps1" -Apply
    Should -Invoke New-ShipsSession -ModuleName DocumentAgent -Times 1 -Exactly -ParameterFilter { $Credential.GetNetworkCredential().Password -eq 'from-env-password' }
    $global:DaSent[0].secret | Should -Be 'from-env-secret'
    (Get-Content "$TestDrive/settings.json" -Raw) | Should -Not -Match 'from-env'
  }
  It 'routes every delivery to a test address when one is given' {
    & "$TestDrive/job.ps1" -Apply -To 'me@example.test'
    $global:DaSent | ForEach-Object { $_.to | Should -Be @('me@example.test') }
  }
  It 'delivers the groups behind a failed one, then fails the run naming it' {
    Mock Get-ShipsDocument -ModuleName DocumentAgent { if ($DocumentId -eq 11) { throw 'portal error for 11' }; ,([Text.Encoding]::ASCII.GetBytes('%PDF-')) }
    { & "$TestDrive/job.ps1" -Apply -MaxSends 0 } | Should -Throw '*1 group(s) failed*A*'
    $global:DaSent.Count | Should -Be 1
    $global:DaSent[0].subject | Should -Be 'Paperwork for C'
    Test-Path "$TestDrive/sent/A.json" | Should -BeFalse
    Test-Path "$TestDrive/sent/C.json" | Should -BeTrue
    Get-DaLog | Should -Contain 'Failed : A: portal error for 11'
  }
  It 'keeps no receipt when the delivery itself fails' {
    Mock Send-FilesViaEmail -ModuleName DocumentAgent { if ($Cfg.mail.subject -match 'C$') { throw 'graph timeout' } }
    { & "$TestDrive/job.ps1" -Apply -MaxSends 0 } | Should -Throw '*C*'
    Test-Path "$TestDrive/sent/A.json" | Should -BeTrue
    Test-Path "$TestDrive/sent/C.json" | Should -BeFalse
    Get-ChildItem "$TestDrive/out" -Filter *.pdf | Should -BeNullOrEmpty
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
