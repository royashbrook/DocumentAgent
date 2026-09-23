@{
  RootModule = 'DocumentAgent.psm1'
  ModuleVersion = '0.3.0'
  GUID = '13b16fdd-dfdb-4955-a738-48df45860bb5'
  Author = 'Roy Ashbrook'
  CompanyName = 'ashbrook.io'
  Copyright = '(c) 2026 royashbrook. All rights reserved.'
  Description = 'A DataAgent variant for documents: list them, group them, fetch each group, deliver it once, keep a receipt. Ships with a SHIPS document source and an email delivery; custom sources and deliveries are .ps1 paths.'
  PowerShellVersion = '7.4'
  RequiredModules = @(
    @{ ModuleName = 'DataAgent'; RequiredVersion = '0.5.0' }
    @{ ModuleName = 'Add-PrefixForLogging'; ModuleVersion = '1.0.0.2' }
    @{ ModuleName = 'ShipsDocuments'; RequiredVersion = '1.0.0' }
    @{ ModuleName = 'Send-FilesViaEmail'; RequiredVersion = '1.0.0' }
  )
  FunctionsToExport = @('Invoke-DocumentAgent', 'New-DocumentAgentConfig')
  AliasesToExport = @()
  CmdletsToExport = @()
  VariablesToExport = @()
  PrivateData = @{
    PSData = @{
      Tags = @('documents', 'delivery', 'ships', 'imaging', 'email', 'dataagent')
      LicenseUri = 'https://github.com/royashbrook/DocumentAgent/blob/main/LICENSE'
      ProjectUri = 'https://github.com/royashbrook/DocumentAgent'
    }
  }
}
