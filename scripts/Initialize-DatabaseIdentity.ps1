function Initialize-DatabaseIdentity {
    param(
        [Parameter(Mandatory)][string]$ServerId,
        [Parameter(Mandatory)][string]$DatabaseHost,
        [Parameter(Mandatory)][Guid]$PrincipalId,
        [Parameter(Mandatory)][string]$AdministratorName
    )

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $pattern = '^/subscriptions/([0-9a-f-]{36})/resourceGroups/([^/]+)/providers/' +
        'Microsoft\.DBforPostgreSQL/flexibleServers/([a-z0-9-]+)$'
    if ($ServerId -notmatch $pattern) {
        throw 'Expected a PostgreSQL Flexible Server resource ID.'
    }
    $subscription = [Guid]::Parse($Matches[1]).ToString()
    $server = $Matches[3]
    if ($DatabaseHost -cne "$server.postgres.database.azure.com" -or
        [string]::IsNullOrWhiteSpace($AdministratorName) -or $PrincipalId -eq [Guid]::Empty) {
        throw 'Invalid database identity provisioning outputs.'
    }
    $sql = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'database-identity.sql') -Raw
    $token = & az account get-access-token --subscription $subscription --resource-type oss-rdbms `
        --query accessToken --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or !$token) {
        throw 'Could not acquire the database administrator token; sign in using az login.'
    }
    $originalPassword = $env:PGPASSWORD
    try {
        $env:PGPASSWORD = ($token -join '').Trim()
        $client = @('run', '--rm', '--interactive', '--env', 'PGPASSWORD',
            '--env', 'PGSSLMODE=verify-full', '--env', 'PGSSLROOTCERT=/etc/ssl/certs/ca-certificates.crt',
            '--env', 'PGCONNECT_TIMEOUT=20', 'postgres:16-alpine', 'psql', '-X',
            '--host', $DatabaseHost, '--username', $AdministratorName, '--dbname', 'postgres',
            '--set', 'ON_ERROR_STOP=1')
        # Firewall updates can take five minutes. Retry connections, not the bootstrap SQL.
        for ($attempt = 0; ; $attempt++) {
            $probe = & docker @client --command 'SELECT 1' 2>&1
            if ($LASTEXITCODE -eq 0) { break }
            if ($LASTEXITCODE -ne 2 -or $attempt -eq 10) {
                Write-Host ($probe -join "`n")
                throw 'Database connection failed. Check the Entra administrator and TCP 5432 egress/firewall access.'
            }
            Write-Host 'Waiting for database connection access before identity setup...'
            Start-Sleep -Seconds 30
        }
        $sql | & docker @client --set "application_oid=$PrincipalId"
        if ($LASTEXITCODE -ne 0) {
            throw 'Database identity setup failed. Verify the Entra administrator, network access, and PostgreSQL client output.'
        }
    } finally {
        $env:PGPASSWORD = $originalPassword
    }
}
