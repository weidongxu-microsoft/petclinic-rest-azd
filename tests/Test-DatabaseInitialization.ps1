param(
    [ValidateSet('postgresql', 'mysql')]
    [string]$DatabaseEngine = 'postgresql',
    [string]$ApplicationImage
)

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

function Invoke-DatabaseQuery {
    param([string]$Username, [string]$Password, [string]$Query, [switch]$ExpectDenied)
    if ($DatabaseEngine -eq 'postgresql') {
        $env:PGPASSWORD = $Password
        $arguments = @('exec', '--env', 'PGPASSWORD', $container, 'psql', '-X',
            '-h', '127.0.0.1', '-U', $Username, '-d', 'petclinic', '-A', '-t',
            '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=sqlstate', '-c', $Query)
    } else {
        $env:MYSQL_PWD = $Password
        $arguments = @('exec', '--env', 'MYSQL_PWD', $container, 'mysql',
            '--host=127.0.0.1', "--user=$Username", '--ssl-mode=REQUIRED',
            '--database=petclinic', '--batch', '--skip-column-names', '--execute', $Query)
    }
    $result = & docker @arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($ExpectDenied) {
        if ($exitCode -eq 0 -or ($result -join "`n") -notmatch '42501|ERROR (1044|1142|1227) \(42000\)') {
            throw "Expected a database permission denial for: $Query"
        }
    } elseif ($exitCode -ne 0) {
        throw "Database query failed: $($result -join "`n")"
    } else {
        return ($result -join "`n").Trim()
    }
}

function Invoke-Initialization {
    $env:APPLICATION_PASSWORD = $runtimePassword
    if ($DatabaseEngine -eq 'postgresql') {
        $env:PGPASSWORD = $administratorPassword
        $arguments = @('exec', '--interactive', '--env', 'PGPASSWORD', '--env', 'APPLICATION_PASSWORD',
            '--env', 'PGHOST=127.0.0.1', '--env', "PGUSER=$administrator", $container)
    } else {
        $env:MYSQL_PWD = $administratorPassword
        $arguments = @('exec', '--interactive', '--env', 'MYSQL_PWD', '--env', 'APPLICATION_PASSWORD',
            '--env', 'MYSQL_HOST=127.0.0.1', '--env', "MYSQL_USER=$administrator",
            '--env', 'MYSQL_SSL_MODE=REQUIRED', '--env', "MYSQL_SSL_CA=$certificate", $container)
    }
    $script | & docker @arguments sh -c 'tr -d "\r" | sh -e'
    if ($LASTEXITCODE -ne 0) {
        throw 'Database initialization failed.'
    }
}

$root = Split-Path $PSScriptRoot -Parent
$applicationParameters = Get-Content -LiteralPath (
    Join-Path $root 'infra\application.parameters.json') -Raw | ConvertFrom-Json -AsHashtable
$engineMapping = $applicationParameters.parameters['databaseEngine']
if ($null -eq $engineMapping -or $engineMapping['value'] -cne '${DATABASE_ENGINE}') {
    throw 'The separate azd service deployment must receive the selected database engine.'
}
$definition = Get-Content -LiteralPath (Join-Path $root 'infra\database-init.bicep') -Raw
if ($definition -notmatch "(?s)var initialization = replace\(.*?'\\r\\n',\s*'\\n'\s*\)") {
    throw 'The deployed initialization command must normalize Windows CRLF to Unix LF.'
}
$images = [regex]::Match($definition, '(?s)var images = \{(.*?)\}')
$certificates = [regex]::Match($definition, '(?s)var certificates = \{(.*?)\}')
$imageMatch = [regex]::Match($images.Groups[1].Value, "\b${DatabaseEngine}: '([^']+)'")
$certificateMatch = [regex]::Match($certificates.Groups[1].Value, "\b${DatabaseEngine}: '([^']+)'")
if (!$imageMatch.Success -or !$certificateMatch.Success) {
    throw 'Database initialization image or TLS root certificate configuration was not found.'
}
$image = $imageMatch.Groups[1].Value
$certificate = $certificateMatch.Groups[1].Value
$platform = if ($DatabaseEngine -eq 'postgresql') { 'postgres' } else { 'mysql' }
$script = (Get-Content -LiteralPath (
    Join-Path $root "infra\scripts\initialize-$DatabaseEngine.sh") -Raw).Replace(
    '__SCHEMA__', (Get-Content -LiteralPath (Join-Path $root "src\main\resources\db\$platform\schema.sql") -Raw)
).Replace('__DATA__', (Get-Content -LiteralPath (Join-Path $root "src\main\resources\db\$platform\data.sql") -Raw))
$script = $script.Replace("`r`n", "`n")

$environmentNames = @('POSTGRES_PASSWORD', 'MYSQL_ROOT_PASSWORD', 'PGPASSWORD', 'MYSQL_PWD',
    'APPLICATION_PASSWORD', 'SPRING_DATASOURCE_PASSWORD', 'SPRING_APPLICATION_JSON')
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$administratorPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$runtimePassword = 'Aa1''\;$#' + [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
$administrator = if ($DatabaseEngine -eq 'postgresql') { 'azdadmin' } else { 'root' }
$env:POSTGRES_PASSWORD = $administratorPassword
$env:MYSQL_ROOT_PASSWORD = $administratorPassword
$env:MYSQL_PWD = $administratorPassword
$container = $null
$application = $null
$network = "petclinic-test-$([Guid]::NewGuid().ToString('N'))"
$networkCreated = $false
try {
    Invoke-Docker @('network', 'create', $network) | Out-Null
    $networkCreated = $true
    $arguments = @('run', '--detach', '--rm', '--network', $network, '--network-alias', 'database')
    if ($DatabaseEngine -eq 'postgresql') {
        $arguments += @('--env', 'POSTGRES_PASSWORD', '--env', 'POSTGRES_USER=azdadmin',
            '--env', 'POSTGRES_DB=petclinic')
    } else {
        $arguments += @('--env', 'MYSQL_ROOT_PASSWORD', '--env', 'MYSQL_DATABASE=petclinic')
    }
    $container = Invoke-Docker ($arguments + $image)
    & docker exec $container test -s $certificate
    if ($LASTEXITCODE -ne 0) {
        throw 'The database initialization image is missing its configured TLS root certificate bundle.'
    }
    $ready = $false
    for ($attempt = 0; $attempt -lt 90; $attempt++) {
        if ($DatabaseEngine -eq 'postgresql') {
            & docker exec $container pg_isready -h 127.0.0.1 -U azdadmin -d petclinic *> $null
        } else {
            & docker exec --env MYSQL_PWD $container mysql --host=127.0.0.1 --user=root `
                --ssl-mode=REQUIRED --execute='SELECT 1' *> $null
        }
        if ($LASTEXITCODE -eq 0) {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if (!$ready) {
        throw "Local $DatabaseEngine did not become ready."
    }

    Invoke-Initialization

    Invoke-DatabaseQuery $administrator $administratorPassword `
        "UPDATE vets SET first_name = 'Preserved' WHERE id = 1; DELETE FROM vets WHERE id = 6" | Out-Null
    $runtimePassword = 'Bb2''\;$#' + [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
    Invoke-Initialization

    $check = @'
SELECT (SELECT count(*) = 5 FROM vets)
AND (SELECT first_name = 'Preserved' FROM vets WHERE id = 1)
AND (SELECT count(*) = 1 FROM azd_template_migrations)
AND (SELECT enabled FROM users WHERE username = 'admin')
AND (SELECT count(*) = 0 FROM users WHERE username = 'petclinic');
'@
    $result = Invoke-DatabaseQuery $administrator $administratorPassword $check
    $expected = if ($DatabaseEngine -eq 'postgresql') { 't' } else { '1' }
    if ($result -ne $expected) {
        throw 'Database repeatability or authorization checks failed.'
    }

    Invoke-DatabaseQuery 'petclinic' $runtimePassword `
        "INSERT INTO vets (first_name, last_name) VALUES ('Runtime', 'Writer')" | Out-Null
    foreach ($query in @(
        'CREATE TABLE unauthorized (id INT)',
        'SELECT * FROM azd_template_migrations',
        'DELETE FROM azd_template_migrations'
    )) {
        Invoke-DatabaseQuery 'petclinic' $runtimePassword $query -ExpectDenied
    }
    $roleQuery = if ($DatabaseEngine -eq 'postgresql') {
        'CREATE ROLE unauthorized LOGIN'
    } else {
        "CREATE USER 'unauthorized'@'%'"
    }
    Invoke-DatabaseQuery 'petclinic' $runtimePassword $roleQuery -ExpectDenied
    if ($ApplicationImage) {
        $env:SPRING_DATASOURCE_PASSWORD = $runtimePassword
        $env:SPRING_APPLICATION_JSON = Get-Content -LiteralPath (
            Join-Path $root 'deployment\spring-configuration.json') -Raw
        $jdbcUrl = if ($DatabaseEngine -eq 'postgresql') {
            'jdbc:postgresql://database:5432/petclinic?sslmode=disable'
        } else {
            'jdbc:mysql://database:3306/petclinic?sslMode=REQUIRED&allowPublicKeyRetrieval=false'
        }
        $application = Invoke-Docker @('run', '--detach', '--rm', '--network', $network,
            '--publish', '127.0.0.1::9966', '--env', "SPRING_PROFILES_ACTIVE=$platform,spring-data-jpa",
            '--env', "SPRING_DATASOURCE_URL=$jdbcUrl",
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
        $healthContent = if ($response.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($response.Content)
        } else {
            [string]$response.Content
        }
        $health = $healthContent | ConvertFrom-Json
        if ($response.StatusCode -ne 200 -or $health.status -ne 'UP' -or
            $healthContent -match '"components"|"details"') {
            throw 'The health endpoint must be available without exposing component details.'
        }
        $user = Invoke-Docker @('inspect', '--format', '{{.Config.User}}', $application)
        if ($user.Trim() -ne '10001:10001') {
            throw 'The packaged application is not configured to run as the expected non-root user.'
        }
        Write-Host 'Packaged application: anonymous API 200, health without details, non-root.'
    }
    Write-Host "$DatabaseEngine initialization, password rotation, least privilege and repeatability passed."
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
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
    }
}
