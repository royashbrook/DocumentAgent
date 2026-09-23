# documents from a SHIPS imaging portal: one login per run, shared through Context
param($Document, [hashtable] $Options, [hashtable] $Context)
if (-not $Context.ships) {
  $credential = [pscredential]::new($Options.Username, (ConvertTo-SecureString $Options.Password -AsPlainText -Force))
  $Context.ships = New-ShipsSession -BaseUrl $Options.BaseUrl -Credential $credential
}
,(Get-ShipsDocument -Session $Context.ships -DocumentId ([long]$Document.document_id))
