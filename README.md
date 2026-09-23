# DocumentAgent

A [DataAgent](https://github.com/royashbrook/DataAgent) variant for documents. It lists documents,
groups them, fetches each group, delivers it once and keeps a receipt. DataAgent still runs the job,
so the log, cleanup and idle marker are the same as every other DataAgent job.

```powershell
Import-Module DocumentAgent   # brings DataAgent, ShipsDocuments and Send-FilesViaEmail with it

$settings = Get-Content "$PSScriptRoot/settings.json" -Raw | ConvertFrom-Json -AsHashtable
# secrets come from the environment, never the committed settings
$settings.items.args.ConnectionString = $env:CONNECTION_STRING
$settings.documents.args.Password = $env:READER_PASSWORD
$settings.delivery.args.msgraph.client_secret = $env:CLIENT_SECRET

Invoke-DataAgent (New-DocumentAgentConfig -Settings $settings -Apply:$Apply -MaxSends $MaxSends -To $To)
```

Call `Invoke-DataAgent` from the job script itself. DataAgent works in the folder of the script that
calls it, so that is where the log, `out/` and the receipts land.

## settings

```json
{
  "keepdays": 30,
  "purgefiles": "*.log",
  "receipts": "sent",
  "items": {
    "adapter": "sql",
    "args": { "InputFile": "get-data.sql", "QueryTimeout": 60 },
    "key": "reference",
    "type": "doc_type",
    "order": "filed_at",
    "require": ["BOL", "FB"]
  },
  "documents": { "adapter": "ships", "args": { "BaseUrl": "https://host/ships5web/", "Username": "reader" } },
  "delivery": {
    "adapter": "email",
    "args": {
      "mail": { "from": "from@example.com", "to": ["to@example.com"], "subject": "Paperwork for {0}", "body": "Attached: {0}" },
      "msgraph": { "tenant_id": "...", "client_id": "..." },
      "contentType": "application/pdf"
    }
  }
}
```

- **items** returns one row per document. Every row needs `document_id` and `file_name`, plus the
  `key` column that groups them. With `type`, the newest row of each type wins, sorted by `order`
  then `document_id`. A group waits until every type in `require` is there. The `sql` source passes
  `args` to `Invoke-Sqlcmd` and returns plain objects.
- **documents** fetches one document's bytes. `ships` logs in to a SHIPS imaging portal once per run
  through ShipsDocuments. Use a login that can view the document ids your query returns.
- **delivery** sends one group. `email` sends one message per group with every file attached, with
  `{0}` in the subject as the key and `{0}` in the body as the file names.

Any adapter can be a `.ps1` path instead of a name:

- items: `param([hashtable] $Options)`, return rows.
- documents: `param($Document, [hashtable] $Options, [hashtable] $Context)`, return the bytes. Context
  lives for the run, for a session or a client.
- delivery: `param([string] $Key, [string[]] $Files, [hashtable] $Options, [string] $To)`. Throw on
  failure. Whatever it returns is kept in the receipt as `delivery`.

## a run

- The source groups the rows and skips any group with a receipt in `receipts/<key>.json`. Nothing
  ready logs `No data available`.
- Without `-Apply`, nothing is fetched and the log names the groups that would go.
- With `-Apply`, each group's files are fetched into `out/`, delivered, then removed, and the receipt
  is written. `-MaxSends` caps the groups per run. `-To` sends every delivery to one test address.
- A group that fails to fetch or deliver gets no receipt and does not stop the others. The run then
  fails, naming it, so it is tried again next run.

Receipts are files, so commit them back from the job if the job runs on a fresh checkout.
