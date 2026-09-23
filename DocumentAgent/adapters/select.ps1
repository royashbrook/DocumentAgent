# DataAgent source: the groups ready to deliver
param($Data, [hashtable] $Options)
& (Get-Module DocumentAgent) { param($o) Select-DocumentGroup -Options $o } $Options
