param(
    [Parameter(Mandatory)]
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
    param([string]$Query)
    $arguments = @('exec', '--env', 'PGPASSWORD', $database, 'psql', '-X',
        '-h', '127.0.0.1', '-U', 'bootstrapadmin', '-d', 'petclinic', '-A', '-t',
        '-v', 'ON_ERROR_STOP=1', '-c', $Query)
    return ((Invoke-Docker $arguments) -join "`n").Trim()
}

function Wait-Application {
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri "$endpoint/api/vets" -SkipHttpErrorCheck -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                return $response
            }
        } catch [System.Net.Http.HttpRequestException] {
            # The server is not listening yet.
        } catch [System.Threading.Tasks.TaskCanceledException] {
            # A request can time out while Spring is still starting.
        }
        Start-Sleep -Seconds 1
    }
    throw 'The packaged application API did not become available within 90 seconds.'
}

function Get-ResponseText {
    param($Response)
    if ($Response.Content -is [byte[]]) {
        return [Text.Encoding]::UTF8.GetString($Response.Content)
    }
    return [string]$Response.Content
}

$root = Split-Path $PSScriptRoot -Parent
$parameters = Get-Content -LiteralPath (Join-Path $root 'infra\application.parameters.json') -Raw |
    ConvertFrom-Json -AsHashtable
if ($parameters.parameters['identityClientId']['value'] -cne '${APPLICATION_IDENTITY_CLIENT_ID}') {
    throw 'The separate azd service deployment must receive the application identity client ID.'
}
$definition = Get-Content -LiteralPath (Join-Path $root 'infra\application.bicep') -Raw
if ($definition -match 'SPRING_APPLICATION_JSON|SPRING_SQL_INIT_MODE|SPRING_JPA_HIBERNATE_DDL_AUTO' -or
    !$definition.Contains("name: 'SPRING_DATASOURCE_USERNAME', value: 'petclinic_app'") -or
    !$definition.Contains('AzurePostgresqlAuthenticationPlugin') -or
    !$definition.Contains('azure.managedIdentityEnabled=true')) {
    throw 'Deployment must use managed identity without overriding application initialization or Spring defaults.'
}

$tableCountQuery = "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' " +
    "AND table_type = 'BASE TABLE'"
$environmentNames = @('POSTGRES_PASSWORD', 'PGPASSWORD', 'SPRING_DATASOURCE_PASSWORD')
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$password = 'Aa1!' + [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
$env:POSTGRES_PASSWORD = $password
$env:PGPASSWORD = $password
$env:SPRING_DATASOURCE_PASSWORD = $password
$database = $null
$application = $null
$network = "petclinic-test-$([Guid]::NewGuid().ToString('N'))"
$networkCreated = $false
try {
    Invoke-Docker @('network', 'create', $network) | Out-Null
    $networkCreated = $true
    $arguments = @('run', '--detach', '--network', $network, '--network-alias', 'database')
    $arguments += @('--env', 'POSTGRES_PASSWORD', '--env', 'POSTGRES_USER=bootstrapadmin',
        '--env', 'POSTGRES_DB=petclinic')
    $database = Invoke-Docker ($arguments + 'postgres:16-alpine')
    $ready = $false
    for ($attempt = 0; $attempt -lt 90; $attempt++) {
        & docker exec $database pg_isready -h 127.0.0.1 -U bootstrapadmin -d petclinic *> $null
        if ($LASTEXITCODE -eq 0) {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if (!$ready) {
        throw 'Local PostgreSQL did not become ready.'
    }
    if ((Invoke-DatabaseQuery $tableCountQuery) -ne '0') {
        throw 'The local application database must be empty before application startup.'
    }
    # Stock PostgreSQL has no Entra extension. Stub only its mapping functions, then run the production SQL.
    $fixture = @'
CREATE ROLE azure_pg_admin;
CREATE TABLE test_entra_mapping (rolname name, objectid uuid, isadmin integer);
CREATE FUNCTION pg_catalog.pgaadauth_list_principals(boolean)
RETURNS TABLE (rolname name, objectid uuid, isadmin integer)
LANGUAGE sql AS 'SELECT * FROM public.test_entra_mapping';
CREATE FUNCTION pg_catalog.pgaadauth_create_principal_with_oid(text, text, text, boolean, boolean)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format('CREATE ROLE %I LOGIN', $1);
    INSERT INTO public.test_entra_mapping VALUES ($1, $2::uuid, 0);
    RETURN $1;
END $$;
'@
    $fixture | & docker exec --interactive $database psql -X -U bootstrapadmin -d postgres -v ON_ERROR_STOP=1 |
        Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not install local Entra mapping fixtures.' }
    $sql = Get-Content -LiteralPath (Join-Path $root 'scripts\database-identity.sql') -Raw
    $principal = [Guid]::NewGuid().ToString()
    foreach ($attempt in 1..2) {
        $sql | & docker exec --interactive $database psql -X -U bootstrapadmin -d postgres `
            -v ON_ERROR_STOP=1 -v "application_oid=$principal" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Identity bootstrap SQL must be repeatable.' }
    }
    $sql | & docker exec --interactive $database psql -X -U bootstrapadmin -d postgres `
        -v ON_ERROR_STOP=1 -v "application_oid=$([Guid]::NewGuid())" *> $null
    if ($LASTEXITCODE -eq 0) { throw 'Bootstrap must reject an identity mapping mismatch.' }
    Invoke-DatabaseQuery 'ALTER ROLE petclinic_app CREATEDB' | Out-Null
    $sql | & docker exec --interactive $database psql -X -U bootstrapadmin -d postgres `
        -v ON_ERROR_STOP=1 -v "application_oid=$principal" *> $null
    if ($LASTEXITCODE -eq 0) { throw 'Bootstrap must reject an existing administrator-capable app role.' }
    Invoke-DatabaseQuery 'ALTER ROLE petclinic_app NOCREATEDB' | Out-Null
    $roleFlags = Invoke-DatabaseQuery "SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls FROM pg_roles WHERE rolname='petclinic_app'"
    if ($roleFlags -ne 'f' -or (Invoke-DatabaseQuery $tableCountQuery) -ne '0') {
        throw 'Bootstrap must create a non-admin login without initializing application tables.'
    }
    "ALTER ROLE petclinic_app PASSWORD '$password';" |
        & docker exec --interactive $database psql -X -U bootstrapadmin -d postgres -v ON_ERROR_STOP=1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure the local-only authentication fixture.' }
    $jdbcUrl = 'jdbc:postgresql://database:5432/petclinic?sslmode=disable'
    $application = Invoke-Docker @('run', '--detach', '--network', $network,
        '--publish', '127.0.0.1::9966', '--env', 'SPRING_PROFILES_ACTIVE=postgres,spring-data-jpa',
        '--env', "SPRING_DATASOURCE_URL=$jdbcUrl", '--env', 'SPRING_DATASOURCE_USERNAME=petclinic_app',
        '--env', 'SPRING_DATASOURCE_PASSWORD', $ApplicationImage)
    $port = Invoke-Docker @('port', $application, '9966/tcp')
    $endpoint = "http://$($port.Trim())/petclinic"
    $response = Wait-Application
    $vets = @(Get-ResponseText $response | ConvertFrom-Json)
    if ($vets.Count -ne 6 -or (Invoke-DatabaseQuery $tableCountQuery) -ne '9') {
        throw 'Application startup must create the nine upstream tables and seed six vets without external SQL setup.'
    }
    $response = Invoke-WebRequest -Uri "$endpoint/actuator/health" -SkipHttpErrorCheck
    $health = Get-ResponseText $response | ConvertFrom-Json
    if ($response.StatusCode -ne 200 -or $health.status -ne 'UP') {
        throw 'The unmodified application health endpoint must report UP.'
    }
    $user = Invoke-Docker @('inspect', '--format', '{{.Config.User}}', $application)
    if ($user.Trim() -ne '10001:10001') {
        throw 'The packaged application must run as the expected non-root OS user.'
    }

    Invoke-DatabaseQuery "UPDATE vets SET first_name = 'Preserved' WHERE id = 1; DELETE FROM vets WHERE id = 6" |
        Out-Null
    Invoke-Docker @('restart', $application) | Out-Null
    $port = Invoke-Docker @('port', $application, '9966/tcp')
    $endpoint = "http://$($port.Trim())/petclinic"
    $response = Wait-Application
    $vets = @(Get-ResponseText $response | ConvertFrom-Json)
    if ($vets.Count -ne 6 -or (Get-ResponseText $response) -notmatch 'Preserved' -or
        (Get-ResponseText $response) -notmatch 'Jenkins') {
        throw 'Restart must retain upstream behavior: rerun seed SQL, restore the missing sample, and preserve existing edits.'
    }
    $ownerCount = Invoke-DatabaseQuery "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tableowner='petclinic_app'"
    if ($ownerCount -ne '9') { throw 'The non-admin app must own the tables it created.' }
    Write-Host 'PostgreSQL: non-admin bootstrap and application-owned initialization/restart passed (local auth fixture, not Entra).'
} catch {
    foreach ($container in @($application, $database)) {
        if ($container) {
            & docker logs --tail 100 $container 2>&1 | Out-Host
        }
    }
    throw
} finally {
    if ($application) {
        Invoke-Docker @('rm', '--force', $application) | Out-Null
    }
    if ($database) {
        Invoke-Docker @('rm', '--force', $database) | Out-Null
    }
    if ($networkCreated) {
        Invoke-Docker @('network', 'rm', $network) | Out-Null
    }
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
    }
}
