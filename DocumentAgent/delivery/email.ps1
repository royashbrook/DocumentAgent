# one email per group with every file attached; subject and body take the key and the file names
param([string] $Key, [string[]] $Files, [hashtable] $Options)
$names = @($Files | Split-Path -Leaf) -join ', '
$mail = @{
  mail = @{ from = $Options.mail.from; to = @($Options.mail.to); subject = ($Options.mail.subject -f $Key); body = ($Options.mail.body -f $names) }
  msgraph = $Options.msgraph
}
$contentType = if ($Options.contentType) { $Options.contentType } else { 'application/octet-stream' }
Send-FilesViaEmail $Files $mail $contentType | Out-Null
@{ to = @($Options.mail.to) }
