$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!$env:AZURE_RESOURCE_GROUP -or !$env:DATABASE_INIT_JOB_NAME -or !$env:AZURE_SUBSCRIPTION_ID) {
    throw 'Missing azd provisioning outputs for the database initialization job.'
}

$jobArguments = @(
    '--subscription', $env:AZURE_SUBSCRIPTION_ID,
    '--resource-group', $env:AZURE_RESOURCE_GROUP,
    '--name', $env:DATABASE_INIT_JOB_NAME,
    '--only-show-errors'
)
$execution = az containerapp job start @jobArguments --query name --output tsv
if ($LASTEXITCODE -ne 0 -or !$execution) {
    throw 'Could not start the database initialization job. Check Azure CLI authentication and job permissions.'
}

Write-Host 'Initializing the database using the isolated Container Apps job.'
$deadline = [DateTime]::UtcNow.AddMinutes(20)
while ([DateTime]::UtcNow -lt $deadline) {
    $status = az containerapp job execution show @jobArguments --job-execution-name $execution `
        --query properties.status --output tsv
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read database initialization execution $execution."
    }
    if ($status -eq 'Succeeded') {
        Write-Host 'Database initialized; the application uses a non-administrator database login.'
        exit 0
    }
    if ($status -in @('Failed', 'Stopped', 'Degraded')) {
        throw "Database initialization $execution ended with status $status. Inspect the job logs before retrying."
    }
    Start-Sleep -Seconds 10
}
throw "Database initialization $execution did not complete within twenty minutes. Inspect the job before retrying."
