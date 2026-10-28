param([string]$ApplicationImage)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Docker {
    param([string[]]$Arguments)
    $result = & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker validation failed: $($Arguments[0])"
    }
    return $result
}

$root = Split-Path $PSScriptRoot -Parent
$definition = Get-Content -LiteralPath (Join-Path $root 'infra\database-init.bicep') -Raw
$image = [regex]::Match($definition, "(?m)^\s+image: '([^']+)'")
$certificate = [regex]::Match($definition, "name: 'PGSSLROOTCERT', value: '([^']+)'")
if (!$image.Success -or !$certificate.Success) {
    throw 'Database initialization image or TLS root certificate configuration was not found.'
}
$match = [regex]::Match($definition, "(?s)var script = '''\r?\n(.*?)\r?\n'''")
if (!$match.Success) {
    throw 'Database initialization script was not found.'
}
$script = $match.Groups[1].Value.Replace(
    '__SCHEMA__', (Get-Content -LiteralPath (Join-Path $root 'src\main\resources\db\postgres\schema.sql') -Raw)
).Replace('__DATA__', (Get-Content -LiteralPath (Join-Path $root 'src\main\resources\db\postgres\data.sql') -Raw))

$originalPassword = $env:POSTGRES_PASSWORD
$env:POSTGRES_PASSWORD = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$container = $null
$application = $null
$network = "petclinic-test-$([Guid]::NewGuid().ToString('N'))"
$networkCreated = $false
try {
    Invoke-Docker @('network', 'create', $network) | Out-Null
    $networkCreated = $true
    $container = Invoke-Docker @('run', '--detach', '--rm', '--env', 'POSTGRES_PASSWORD',
        '--network', $network, '--network-alias', 'database',
        '--env', 'POSTGRES_USER=azdadmin', '--env', 'POSTGRES_DB=petclinic', $image.Groups[1].Value)
    & docker exec $container test -s $certificate.Groups[1].Value
    if ($LASTEXITCODE -ne 0) {
        throw 'The database initialization image is missing its configured TLS root certificate bundle.'
    }
    $ready = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        & docker exec $container pg_isready -h 127.0.0.1 -U azdadmin -d petclinic *> $null
        if ($LASTEXITCODE -eq 0) {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if (!$ready) {
        throw 'Local PostgreSQL did not become ready.'
    }

    $env:PGPASSWORD = $env:POSTGRES_PASSWORD
    $env:APPLICATION_PASSWORD = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    $script = $script.Replace("`r`n", "`n")
    $script | & docker exec --interactive --env PGPASSWORD --env APPLICATION_PASSWORD `
        --env PGHOST=127.0.0.1 --env PGUSER=azdadmin $container sh -c 'tr -d "\r" | sh -e'
    if ($LASTEXITCODE -ne 0) {
        throw 'Initial database setup failed.'
    }

    Invoke-Docker @('exec', $container, 'psql', '-X', '-U', 'azdadmin', '-d', 'petclinic',
        '-v', 'ON_ERROR_STOP=1', '-c', "UPDATE vets SET first_name = 'Preserved' WHERE id = 1") | Out-Null
    $script | & docker exec --interactive --env PGPASSWORD --env APPLICATION_PASSWORD `
        --env PGHOST=127.0.0.1 --env PGUSER=azdadmin $container sh -c 'tr -d "\r" | sh -e'
    if ($LASTEXITCODE -ne 0) {
        throw 'Repeated database setup failed.'
    }

    $check = @'
SELECT (SELECT count(*) = 6 FROM vets)
AND (SELECT first_name = 'Preserved' FROM vets WHERE id = 1)
AND (SELECT count(*) = 1 FROM azd_template_migrations)
AND (SELECT enabled FROM users WHERE username = 'admin')
AND (SELECT count(*) = 0 FROM users WHERE username = 'petclinic')
AND NOT has_schema_privilege('petclinic', 'public', 'CREATE')
AND NOT has_table_privilege('petclinic', 'azd_template_migrations', 'DELETE');
'@
    $result = Invoke-Docker @('exec', $container, 'psql', '-X', '-U', 'azdadmin', '-d', 'petclinic',
        '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c', $check)
    if ($result.Trim() -ne 't') {
        throw 'Database repeatability or authorization checks failed.'
    }

    $env:PGPASSWORD = $env:APPLICATION_PASSWORD
    Invoke-Docker @('exec', '--env', 'PGPASSWORD', $container, 'psql', '-X', '-h', '127.0.0.1',
        '-U', 'petclinic', '-d', 'petclinic', '-v', 'ON_ERROR_STOP=1', '-c',
        "INSERT INTO vets (first_name, last_name) VALUES ('Runtime', 'Writer')") | Out-Null
    if ($ApplicationImage) {
        $env:SPRING_DATASOURCE_PASSWORD = $env:APPLICATION_PASSWORD
        $env:SPRING_APPLICATION_JSON = Get-Content -LiteralPath (
            Join-Path $root 'deployment\spring-configuration.json') -Raw
        $application = Invoke-Docker @('run', '--detach', '--rm', '--network', $network,
            '--publish', '127.0.0.1::9966', '--env', 'SPRING_PROFILES_ACTIVE=postgres,spring-data-jpa',
            '--env', 'SPRING_DATASOURCE_URL=jdbc:postgresql://database:5432/petclinic?sslmode=disable',
            '--env', 'SPRING_DATASOURCE_USERNAME=petclinic', '--env', 'SPRING_DATASOURCE_PASSWORD',
            '--env', 'SPRING_APPLICATION_JSON',
            $ApplicationImage)
        $port = Invoke-Docker @('port', $application, '9966/tcp')
        $url = "http://$($port.Trim())/petclinic/api/vets"
        $ready = $false
        for ($attempt = 0; $attempt -lt 90; $attempt++) {
            try {
                $response = Invoke-WebRequest -Uri $url -SkipHttpErrorCheck -TimeoutSec 2
                if ($response.StatusCode -eq 200) {
                    $ready = $true
                    break
                }
            } catch [System.Net.Http.HttpRequestException] {
                # The server is not listening yet.
            }
            Start-Sleep -Seconds 1
        }
        if (!$ready) {
            throw 'The packaged application API did not become available within 90 seconds.'
        }
        if ($response.StatusCode -ne 200 -or $response.Content -notmatch 'Preserved') {
            throw 'The packaged application could not read the initialized database without API authentication.'
        }
        $response = Invoke-WebRequest -Uri ($url -replace '/api/vets$', '/actuator/health') -SkipHttpErrorCheck
        if ($response.StatusCode -ne 200 -or $response.Content -match '"components"|"details"') {
            throw 'The health endpoint must be available without exposing component details.'
        }
        $user = Invoke-Docker @('inspect', '--format', '{{.Config.User}}', $application)
        if ($user.Trim() -ne '10001:10001') {
            throw 'The packaged application is not configured to run as the expected non-root user.'
        }
        Write-Host 'Packaged application: anonymous API 200, health without details, non-root.'
    }
    Write-Host 'Database initialization, database password authentication, least privilege and repeatability passed.'
} finally {
    if ($application) {
        & docker rm --force $application | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Could not remove validation application $application."
        }
    }
    if ($container) {
        & docker rm --force $container | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Could not remove validation container $container."
        }
    }
    if ($networkCreated) {
        & docker network rm $network | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Could not remove validation network $network."
        }
    }
    $env:POSTGRES_PASSWORD = $originalPassword
    Remove-Item Env:\PGPASSWORD, Env:\APPLICATION_PASSWORD, Env:\SPRING_DATASOURCE_PASSWORD, Env:\SPRING_APPLICATION_JSON `
        -ErrorAction SilentlyContinue
}
