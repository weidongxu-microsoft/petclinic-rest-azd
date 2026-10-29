$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!$env:AZURE_SUBSCRIPTION_ID) {
    throw 'Select an Azure subscription before provisioning.'
}
foreach ($tool in @('az', 'docker')) {
    if (!(Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Install $tool before provisioning."
    }
}
& docker info --format '{{.ServerVersion}}' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Start Docker before provisioning; the database identity setup uses the PostgreSQL client image.'
}
$json = & az ad signed-in-user show --subscription $env:AZURE_SUBSCRIPTION_ID --only-show-errors --output json
if ($LASTEXITCODE -ne 0) {
    throw 'Sign in to Azure CLI with a user account in the selected subscription tenant using az login.'
}
$user = ConvertFrom-Json -InputObject ($json -join "`n")
$id = [Guid]::Parse($user.id).ToString()
if ([string]::IsNullOrWhiteSpace($user.userPrincipalName)) {
    throw 'The signed-in Azure CLI user must have a user principal name.'
}
foreach ($value in @(
    @('DATABASE_ADMIN_OBJECT_ID', $id),
    @('DATABASE_ADMIN_NAME', $user.userPrincipalName)
)) {
    & azd env set @value
    if ($LASTEXITCODE -ne 0) {
        throw "Could not save $($value[0]) in the azd environment."
    }
}
