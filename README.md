# DocumentAgent

A [DataAgent](https://github.com/royashbrook/DataAgent) variant for documents. It lists documents,
groups them, fetches each group, delivers it once and keeps a receipt. DataAgent still runs the job,
so the log, cleanup and idle marker are the same as every other DataAgent job.

```powershell
Import-Module DocumentAgent   # brings DataAgent, ShipsDocuments and Send-FilesViaEmail with it
Invoke-DocumentAgent "$PSScriptRoot/settings.json"
```

The run works in the settings file's folder: the log, `out/` and the receipts land there, wherever the
call comes from. Any value written as `env:NAME` is read from that environment variable, so the
committed file holds names, never secrets. Like any feed, a run delivers everything that is ready.
To test, point the delivery at yourself and add `"dry_run": true` (name what would go, send
nothing) or `"max_sends": 1` (cap the run) to the settings. `New-DocumentAgentConfig` returns the
DataAgent config without running it.

## settings

```json
{
  "keepdays": 30,
  "purgefiles": "*.log",
  "receipts": "sent",
  "dry_run": false,
  "max_sends": 0,
  "items": {
    "adapter": "sql",
    "args": { "InputFile": "get-data.sql", "QueryTimeout": 60, "ConnectionString": "env:CONNECTION_STRING" },
    "key": "reference",
    "type": "doc_type",
    "order": "filed_at",
    "require": ["BOL", "FB"]
  },
  "documents": { "adapter": "ships", "args": { "BaseUrl": "https://host/ships5web/", "Username": "reader", "Password": "env:READER_PASSWORD" } },
  "delivery": {
    "adapter": "email",
    "args": {
      "mail": { "from": "from@example.com", "to": ["to@example.com"], "subject": "Paperwork for {0}", "body": "Attached: {0}" },
      "msgraph": { "tenant_id": "...", "client_id": "...", "client_secret": "env:CLIENT_SECRET" },
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
- delivery: `param([string] $Key, [string[]] $Files, [hashtable] $Options)`. Throw on
  failure. Whatever it returns is kept in the receipt as `delivery`. Add `[object[]] $Documents`
  to the params to also get the group's rows, in the same order as the files.

A custom adapter that reads or writes files through .NET should use full paths. The run moves
PowerShell's location to the settings folder, not the process working directory.

## a run

- The source groups the rows and skips any group with a receipt in `receipts/<key>.json`. Nothing
  ready logs `No data available`.
- With `dry_run`, nothing is fetched and the log names the groups that would go.
- Otherwise each document is fetched once into `out/<document_id>/`, even when it goes out in
  several groups, then each group is delivered and gets its receipt. The files are removed when the
  run ends. `max_sends` caps the groups per run (0 or absent for none).
- A group that fails to fetch or deliver gets no receipt and does not stop the others. The run then
  fails, naming it, so it is tried again next run.

Receipts are files, so commit them back from the job if the job runs on a fresh checkout.
