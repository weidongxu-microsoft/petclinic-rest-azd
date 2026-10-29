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
    $group = $Matches[2]
    $server = $Matches[3]
    if ($DatabaseHost -cne "$server.postgres.database.azure.com" -or
        [string]::IsNullOrWhiteSpace($AdministratorName) -or $PrincipalId -eq [Guid]::Empty) {
        throw 'Invalid database identity provisioning outputs.'
    }
    $sql = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'database-identity.sql') -Raw
    $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15).Trim()
    $address = $null
    if (![Net.IPAddress]::TryParse($ip, [ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $address.ToString() -cne $ip) {
        throw 'Could not discover a canonical public IPv4 address for the temporary database firewall rule.'
    }
    $token = & az account get-access-token --subscription $subscription --resource-type oss-rdbms `
        --query accessToken --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or !$token) {
        throw 'Could not acquire the database administrator token; sign in using az login.'
    }
    $scope = @('--subscription', $subscription, '--resource-group', $group, '--server-name', $server,
        '--only-show-errors')
    $rule = "petclinic-bootstrap-$([Guid]::NewGuid().ToString('N'))"
    $originalPassword = $env:PGPASSWORD
    try {
        # Also attempt cleanup if the create request succeeds remotely but its response is lost.
        & az postgres flexible-server firewall-rule create @scope --name $rule `
            --start-ip-address $ip --end-ip-address $ip --output none
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not create the temporary database bootstrap firewall rule.'
        }
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
        & az postgres flexible-server firewall-rule delete @scope --name $rule --yes --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Remove temporary firewall rule '$rule' from '$server'; automatic cleanup failed."
        }
    }
    Write-Host 'Non-admin database identity configured; Petclinic will create and seed its own tables.'
}
