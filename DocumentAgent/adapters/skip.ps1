# DataAgent destination for a dry run: name what would go, send nothing
param($Data, [hashtable] $Options)
$keys = @(Get-Content -LiteralPath ([string]$Data) -Raw | ConvertFrom-Json | ForEach-Object key)
l "Dry run, not sending: $($keys -join ', ')"
