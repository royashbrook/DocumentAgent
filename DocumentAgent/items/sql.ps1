# items from a query: every argument goes to Invoke-Sqlcmd; rows come back as plain objects
param([hashtable] $Options)
Import-Module SqlServer -RequiredVersion 22.4.5.1 -Cmdlet Invoke-Sqlcmd
Invoke-Sqlcmd @Options -OutputAs DataRows | ForEach-Object {
  $row = $_
  $item = [ordered]@{}
  foreach ($column in $row.Table.Columns) { $item[$column.ColumnName] = if ($row[$column] -is [DBNull]) { $null } else { $row[$column] } }
  [pscustomobject]$item
}
