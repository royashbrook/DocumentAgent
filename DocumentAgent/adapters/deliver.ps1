# DataAgent destination: deliver each group once and write its receipt
param($Data, [hashtable] $Options)
& (Get-Module DocumentAgent) { param($p, $o) Send-DocumentGroup -Path $p -Options $o } ([string]$Data) $Options
