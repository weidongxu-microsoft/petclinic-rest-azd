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
        '--env', 'POSTGRES_USER=azdadmin', '--env', 'POSTGRES_DB=petclinic', 'postgres:16-bookworm')
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
    $env:API_PASSWORD = 'test-only-generated-api-password'
    $script = $script.Replace("`r`n", "`n")
    $script | & docker exec --interactive --env PGPASSWORD --env APPLICATION_PASSWORD --env API_PASSWORD `
        --env PGHOST=127.0.0.1 --env PGUSER=azdadmin $container sh -c 'tr -d "\r" | sh -e'
    if ($LASTEXITCODE -ne 0) {
        throw 'Initial database setup failed.'
    }

    Invoke-Docker @('exec', $container, 'psql', '-X', '-U', 'azdadmin', '-d', 'petclinic',
        '-v', 'ON_ERROR_STOP=1', '-c', "UPDATE vets SET first_name = 'Preserved' WHERE id = 1") | Out-Null
    $script | & docker exec --interactive --env PGPASSWORD --env APPLICATION_PASSWORD --env API_PASSWORD `
        --env PGHOST=127.0.0.1 --env PGUSER=azdadmin $container sh -c 'tr -d "\r" | sh -e'
    if ($LASTEXITCODE -ne 0) {
        throw 'Repeated database setup failed.'
    }

    $check = @'
SELECT (SELECT count(*) = 6 FROM vets)
AND (SELECT first_name = 'Preserved' FROM vets WHERE id = 1)
AND (SELECT count(*) = 1 FROM azd_template_migrations)
AND (SELECT NOT enabled FROM users WHERE username = 'admin')
AND (SELECT password = crypt('test-only-generated-api-password', password) FROM users WHERE username = 'petclinic')
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
        $application = Invoke-Docker @('run', '--detach', '--rm', '--network', $network,
            '--publish', '127.0.0.1::9966', '--env', 'SPRING_PROFILES_ACTIVE=postgres,spring-data-jpa,azure',
            '--env', 'SPRING_DATASOURCE_URL=jdbc:postgresql://database:5432/petclinic?sslmode=disable',
            '--env', 'SPRING_DATASOURCE_USERNAME=petclinic', '--env', 'SPRING_DATASOURCE_PASSWORD',
            $ApplicationImage)
        $port = Invoke-Docker @('port', $application, '9966/tcp')
        $url = "http://$($port.Trim())/petclinic/api/vets"
        $ready = $false
        for ($attempt = 0; $attempt -lt 90; $attempt++) {
            try {
                $response = Invoke-WebRequest -Uri $url -SkipHttpErrorCheck -TimeoutSec 2
                if ($response.StatusCode -eq 401) {
                    $ready = $true
                    break
                }
            } catch [System.Net.Http.HttpRequestException] {
                # The server is not listening yet.
            }
            Start-Sleep -Seconds 1
        }
        if (!$ready) {
            throw 'The packaged application did not require authentication within 90 seconds.'
        }
        $credentials = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("petclinic:$env:API_PASSWORD"))
        $response = Invoke-WebRequest -Uri $url -Headers @{ Authorization = "Basic $credentials" } -SkipHttpErrorCheck
        if ($response.StatusCode -ne 200 -or $response.Content -notmatch 'Preserved') {
            throw 'The packaged application could not authenticate against the initialized database.'
        }
        $sampleCredentials = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('admin:admin'))
        $response = Invoke-WebRequest -Uri $url -Headers @{ Authorization = "Basic $sampleCredentials" } -SkipHttpErrorCheck
        if ($response.StatusCode -ne 401) {
            throw 'The packaged application accepted the sample administrator.'
        }
        $user = Invoke-Docker @('inspect', '--format', '{{.Config.User}}', $application)
        if ($user.Trim() -ne '10001:10001') {
            throw 'The packaged application is not configured to run as the expected non-root user.'
        }
        Write-Host 'Packaged application: anonymous 401, configured user 200, sample admin 401, non-root.'
    }
    Write-Host 'Database initialization, password authentication, API hash, least privilege and repeatability passed.'
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
    Remove-Item Env:\PGPASSWORD, Env:\APPLICATION_PASSWORD, Env:\API_PASSWORD, Env:\SPRING_DATASOURCE_PASSWORD `
        -ErrorAction SilentlyContinue
}
