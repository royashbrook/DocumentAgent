# DataAgent formatter: fetch each group's documents and write the manifest
param($Data, [hashtable] $Options)
& (Get-Module DocumentAgent) { param($d, $o) Save-GroupDocument -Data $d -Options $o } $Data $Options
