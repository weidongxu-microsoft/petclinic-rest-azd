$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot 'Update-DatabaseFirewall.ps1')
. (Join-Path $PSScriptRoot 'Initialize-DatabaseIdentity.ps1')
Initialize-DatabaseIdentity -ServerId $env:DATABASE_SERVER_ID -DatabaseHost $env:DATABASE_HOST `
    -PrincipalId $env:APPLICATION_PRINCIPAL_ID -AdministratorName $env:DATABASE_ADMIN_NAME
