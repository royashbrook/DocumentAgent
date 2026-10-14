BeforeAll {
  Import-Module "$PSScriptRoot/../DocumentAgent/DocumentAgent.psd1" -Force
  $script:CleanupLocation = Get-Location
  function Invoke-CleanupFixture([hashtable]$Extra = @{}) {
    $settings = @{
      keepdays = 2; purgefiles = '*.csv'; dry_run = $true
      items = @{ adapter = "$script:CleanupDirectory/empty.ps1"; args = @{}; key = 'id' }
    }
    foreach ($key in $Extra.Keys) { $settings[$key] = $Extra[$key] }
    $settings | ConvertTo-Json -Depth 5 | Set-Content "$script:CleanupDirectory/settings.json"
    Invoke-DocumentAgent "$script:CleanupDirectory/settings.json"
  }
}

Describe 'job-file cleanup' {
  BeforeEach {
    $script:CleanupDirectory = (New-Item -ItemType Directory "$TestDrive/$([guid]::NewGuid().ToString('N'))").FullName
    'param([hashtable]$Options) @()' | Set-Content "$script:CleanupDirectory/empty.ps1"
  }
  It 'does not add either filename-date setting when absent' {
    $config = New-DocumentAgentConfig @{ items = @{}; keepdays = 2; purgefiles = '*.csv' }
    $config.keepdays | Should -Be 2
    $config.purgefiles | Should -Be '*.csv'
    $config.ContainsKey('filename_date_format') | Should -BeFalse
    $config.ContainsKey('filename_date_pattern') | Should -BeFalse
  }
  It 'passes both optional settings unchanged, including explicit invalid values' {
    foreach ($value in @('yyyyMMdd', '', $null)) {
      $config = New-DocumentAgentConfig @{ items = @{}; filename_date_format = $value; filename_date_pattern = '(?<date>\d{8})' }
      $config.ContainsKey('filename_date_format') | Should -BeTrue
      $config.filename_date_format | Should -BeExactly $value
      $config.filename_date_pattern | Should -BeExactly '(?<date>\d{8})'
    }
  }
  It 'keeps default mtime cleanup even when the filename says a different date' {
    $old = Join-Path $script:CleanupDirectory ('{0:yyyyMMdd}-old.csv' -f (Get-Date).AddDays(1))
    $fresh = Join-Path $script:CleanupDirectory '20000101-fresh.csv'
    'old' | Set-Content $old
    'fresh' | Set-Content $fresh
    (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-10)
    Invoke-CleanupFixture
    Test-Path $old | Should -BeFalse
    Test-Path $fresh | Should -BeTrue
  }
  It 'deletes an expired day-prefix file with fresh mtime and keeps a recent one' {
    $old = Join-Path $script:CleanupDirectory ('{0:yyyyMMdd}-old.csv' -f (Get-Date).AddDays(-10))
    $fresh = Join-Path $script:CleanupDirectory ('{0:yyyyMMdd}-fresh.csv' -f (Get-Date))
    '' | Set-Content $old -NoNewline
    'fresh' | Set-Content $fresh
    Invoke-CleanupFixture @{ filename_date_format = 'yyyyMMdd' }
    Test-Path $old | Should -BeFalse
    Test-Path $fresh | Should -BeTrue
  }
  It 'uses the named date capture away from the filename prefix' {
    $old = Join-Path $script:CleanupDirectory ('report-{0:yyyyMMdd}-old.csv' -f (Get-Date).AddDays(-10))
    $fresh = Join-Path $script:CleanupDirectory ('report-{0:yyyyMMdd}-fresh.csv' -f (Get-Date))
    'old' | Set-Content $old
    'fresh' | Set-Content $fresh
    Invoke-CleanupFixture @{ filename_date_format = 'yyyyMMdd'; filename_date_pattern = '(?<date>\d{8})' }
    Test-Path $old | Should -BeFalse
    Test-Path $fresh | Should -BeTrue
  }
  It 'refuses an invalid explicit format before deleting any file' {
    $old = Join-Path $script:CleanupDirectory '20000101-old.csv'
    'old' | Set-Content $old
    (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-10)
    { Invoke-CleanupFixture @{ filename_date_format = '' } } | Should -Throw
    Test-Path $old | Should -BeTrue
  }
}

AfterAll { Set-Location $script:CleanupLocation }
