$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\Initialize-DatabaseIdentity.ps1')
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}
function Get-Argument {
    param([object[]]$Arguments, [string]$Name)
    $index = [Array]::IndexOf($Arguments, $Name)
    Assert-True ($index -ge 0 -and $index + 1 -lt $Arguments.Count) "Missing argument: $Name"
    return $Arguments[$index + 1]
}
function Invoke-RestMethod {
    param($Uri, $TimeoutSec)
    throw 'Bootstrap must not depend on HTTPS IP discovery.'
}
function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    Assert-True ((Get-Argument $arguments '--subscription') -eq $subscription) 'Wrong subscription.'
    if ($arguments[0] -eq 'account') {
        $state.TokenCalls++
        if ($state.Failure -eq 'token') { $global:LASTEXITCODE = 1; return }
        return 'synthetic-sensitive-token'
    }
    Assert-True (($arguments[0..2] -join ' ') -eq 'postgres flexible-server firewall-rule') 'Unexpected Azure mutation.'
    Assert-True ((Get-Argument $arguments '--resource-group') -eq 'test-group') 'Wrong resource group.'
    Assert-True ((Get-Argument $arguments '--server-name') -eq 'test-server') 'Wrong server.'
    if ($arguments[3] -eq 'list') {
        $state.FirewallLists++
        if ($state.Failure -eq 'firewall') { $global:LASTEXITCODE = 1; return }
        return ConvertTo-Json -InputObject @(
            @{ name = 'aca-203-0-113-1'; startIpAddress = '203.0.113.1'; endIpAddress = '203.0.113.1' }
            @{ name = 'bootstrap-local-ip'; startIpAddress = '0.0.0.0'; endIpAddress = '255.255.255.255' }
        ) -Compress
    }
    $rule = Get-Argument $arguments '--name'
    Assert-True ($arguments[3] -eq 'delete' -and $rule -ceq 'bootstrap-local-ip') `
        'Cleanup must delete only the Bicep-created temporary rule, not ACA rules.'
    $state.Deleted = $rule
    $state.DeleteCalls++
    if ($state.Failure -eq 'delete') { $global:LASTEXITCODE = 1 }
}
function Start-Sleep {
    param([int]$Seconds)
    Assert-True ($Seconds -eq 30) 'Unexpected connection retry delay.'
    $state.Sleeps++
}
function docker {
    $arguments = @($args)
    $state.DockerCalls++
    $global:LASTEXITCODE = 0
    Assert-True ($env:PGPASSWORD -ceq 'synthetic-sensitive-token') 'Token must be passed through the environment.'
    Assert-True (($arguments -join ' ') -notmatch 'synthetic-sensitive-token') 'Token must not appear in command arguments.'
    foreach ($setting in @('PGSSLMODE=verify-full', 'PGSSLROOTCERT=/etc/ssl/certs/ca-certificates.crt',
        'PGCONNECT_TIMEOUT=20')) {
        Assert-True ($arguments -contains $setting) "Missing client protection: $setting"
    }
    Assert-True ((Get-Argument $arguments '--host') -ceq 'test-server.postgres.database.azure.com') 'Wrong database host.'
    Assert-True ((Get-Argument $arguments '--username') -ceq 'admin@example.invalid') 'Wrong administrator.'
    if ($arguments -contains '--command') {
        Assert-True ((Get-Argument $arguments '--command') -ceq 'SELECT 1') 'Connection retries must not mutate the database.'
        $state.ProbeCalls++
        if ($state.Failure -eq 'unreachable' -or
            ($state.Failure -eq 'delayed' -and $state.ProbeCalls -le 2)) {
            $global:LASTEXITCODE = 2
        } elseif ($state.Failure -eq 'client') {
            $global:LASTEXITCODE = 125
        }
        return
    }
    $state.SqlCalls++
    $sql = $input | Out-String
    Assert-True ($sql.Contains('pgaadauth_create_principal_with_oid') -and
        !$sql.Contains('CREATE TABLE') -and !$sql.Contains('INSERT INTO')) 'Bootstrap must only map identity and grant permissions.'
    if ($state.Failure -eq 'sql') { $global:LASTEXITCODE = 1 }
}

$subscription = '00000000-0000-0000-0000-000000000001'
$serverId = "/subscriptions/$subscription/resourceGroups/test-group/providers/" +
    'Microsoft.DBforPostgreSQL/flexibleServers/test-server'
$state = @{}
$originalPassword = $env:PGPASSWORD
try {
    $env:PGPASSWORD = 'original-test-value'
    foreach ($scenario in @('success', 'token', 'sql', 'host', 'delayed', 'unreachable', 'client')) {
        $state = @{
            Failure = $scenario
            TokenCalls = 0; DockerCalls = 0
            ProbeCalls = 0; SqlCalls = 0; Sleeps = 0
        }
        $hostName = if ($scenario -eq 'host') { 'attacker.invalid' } else { 'test-server.postgres.database.azure.com' }
        $failure = $null
        $output = ''
        try {
            $output = Initialize-DatabaseIdentity -ServerId $serverId -DatabaseHost $hostName `
                -PrincipalId '00000000-0000-0000-0000-000000000002' `
                -AdministratorName 'admin@example.invalid' 6>&1 | Out-String
        } catch { $failure = $_.Exception.Message }
        Assert-True ($env:PGPASSWORD -ceq 'original-test-value') "$scenario failed to restore the prior environment."
        Assert-True ($output -notmatch 'synthetic-sensitive-token' -and
            $failure -notmatch 'synthetic-sensitive-token') "$scenario disclosed a token."
        if ($scenario -in @('success', 'delayed')) {
            Assert-True ($null -eq $failure -and $state.SqlCalls -eq 1) "Successful setup failed: $failure"
        } else {
            Assert-True ($null -ne $failure) "$scenario should fail."
        }
        if ($scenario -eq 'host') {
            Assert-True ($state.TokenCalls -eq 0 -and $state.DockerCalls -eq 0) 'Invalid host must fail before network access.'
        }
        if ($scenario -eq 'delayed') {
            Assert-True ($state.ProbeCalls -eq 3 -and $state.Sleeps -eq 2) 'Transient connections must be retried.'
        } elseif ($scenario -eq 'unreachable') {
            Assert-True ($state.ProbeCalls -eq 11 -and $state.Sleeps -eq 10 -and $state.SqlCalls -eq 0) `
                'Connection retries must be bounded and must not run bootstrap SQL when access fails.'
        } elseif ($scenario -eq 'sql') {
            Assert-True ($state.ProbeCalls -eq 1 -and $state.SqlCalls -eq 1 -and $state.Sleeps -eq 0) `
                'Bootstrap SQL must not be replayed after a failure.'
        } elseif ($scenario -eq 'client') {
            Assert-True ($state.ProbeCalls -eq 1 -and $state.SqlCalls -eq 0 -and $state.Sleeps -eq 0) `
                'Docker failures must fail immediately rather than retrying database access.'
        }
    }
} finally {
    $env:PGPASSWORD = $originalPassword
}
Write-Host 'Seven identity-bootstrap scenarios passed, including bounded connection retries, TLS, and token non-disclosure.'

$hookEnvironment = @('DATABASE_SERVER_ID', 'DATABASE_HOST', 'APPLICATION_PRINCIPAL_ID',
    'DATABASE_ADMIN_NAME', 'DATABASE_OUTBOUND_IPS')
$savedHookEnvironment = @{}
foreach ($name in $hookEnvironment) {
    $savedHookEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
try {
    $env:DATABASE_SERVER_ID = $serverId
    $env:DATABASE_HOST = 'test-server.postgres.database.azure.com'
    $env:APPLICATION_PRINCIPAL_ID = '00000000-0000-0000-0000-000000000002'
    $env:DATABASE_ADMIN_NAME = 'admin@example.invalid'
    $env:DATABASE_OUTBOUND_IPS = '["203.0.113.1"]'
    foreach ($scenario in @('success', 'firewall', 'token', 'sql', 'delete')) {
        $state = @{
            Failure = $scenario; TokenCalls = 0; DockerCalls = 0; ProbeCalls = 0; SqlCalls = 0
            Sleeps = 0; FirewallLists = 0; Deleted = ''; DeleteCalls = 0
        }
        $failure = $null
        $output = ''
        try {
            $output = & (Join-Path $root 'scripts\Configure-Database.ps1') 6>&1 | Out-String
        } catch { $failure = $_.Exception.Message }
        Assert-True ($state.Deleted -ceq 'bootstrap-local-ip' -and $state.DeleteCalls -eq 1) `
            "$scenario must remove temporary full-IPv4 access, including on reconciliation/authentication/SQL failures."
        Assert-True ($env:PGPASSWORD -ceq $originalPassword) "$scenario must restore the prior password environment."
        Assert-True ($output -notmatch 'synthetic-sensitive-token' -and
            $failure -notmatch 'synthetic-sensitive-token') "$scenario disclosed a token."
        if ($scenario -eq 'success') {
            Assert-True ($null -eq $failure -and $state.SqlCalls -eq 1) "Postprovision failed: $failure"
        } else {
            Assert-True ($null -ne $failure -and $output -notmatch 'identity configured') `
                "$scenario must fail without reporting bootstrap success."
        }
        if ($scenario -eq 'delete') {
            Assert-True ($failure -match "Remove temporary firewall rule 'bootstrap-local-ip'") `
                'Cleanup failure must report the rule requiring manual removal.'
        }
        if ($scenario -in @('firewall', 'token')) {
            Assert-True ($state.SqlCalls -eq 0) "$scenario must not run SQL."
        }
    }
} finally {
    foreach ($name in $hookEnvironment) {
        [Environment]::SetEnvironmentVariable($name, $savedHookEnvironment[$name])
    }
}
Write-Host 'Five postprovision scenarios passed, including full-IPv4 cleanup on success and all failure stages.'

function docker {
    Assert-True (($args -join ' ') -eq 'info --format {{.ServerVersion}}') 'Unexpected preflight Docker command.'
    $global:LASTEXITCODE = if ($state.Failure -eq 'docker') { 1 } else { 0 }
}
function az {
    Assert-True ((Get-Argument $args '--subscription') -eq $subscription) 'Preflight must use the selected subscription.'
    $global:LASTEXITCODE = 0
    if (($args[0..1] -join ' ') -eq 'account show') {
        if ($state.Failure -eq 'user') { $global:LASTEXITCODE = 1; return }
        $type = if ($state.Failure -eq 'service-principal') { 'servicePrincipal' } else { 'user' }
        return @{
            tenantId = $tenant
            user = @{ name = 'cached-alias@example.invalid'; type = $type }
        } | ConvertTo-Json
    }
    Assert-True (($args[0..1] -join ' ') -eq 'account get-access-token') 'Preflight must not require Graph.'
    Assert-True ((Get-Argument $args '--resource-type') -eq 'arm') 'Preflight must reuse the ARM credential.'
    if ($state.Failure -eq 'arm-token') { $global:LASTEXITCODE = 1; return }
    if ($state.Failure -eq 'malformed-token') { return 'synthetic-sensitive-token' }
    $claims = @{
        oid = if ($state.Failure -eq 'missing-oid') { '' } else { '00000000-0000-0000-0000-000000000003' }
        tid = if ($state.Failure -eq 'wrong-tenant') { '00000000-0000-0000-0000-000000000099' } else { $tenant }
        upn = if ($state.Failure -in @('preferred-name', 'unique-name', 'missing-name')) { '' } else {
            'admin@example.invalid'
        }
        preferred_username = if ($state.Failure -eq 'preferred-name') { 'admin@example.invalid' } else { '' }
        unique_name = if ($state.Failure -eq 'unique-name') { 'admin@example.invalid' } else { '' }
    } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).
        TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return "header.$payload.synthetic-sensitive-token"
}
function azd {
    Assert-True (($args[0..1] -join ' ') -eq 'env set') 'Only administrator metadata may be persisted.'
    Assert-True ($args[2] -in @('DATABASE_ADMIN_OBJECT_ID', 'DATABASE_ADMIN_NAME')) 'Do not persist credentials.'
    $state.Values[$args[2]] = $args[3]
    $global:LASTEXITCODE = 0
}
$originalSubscription = $env:AZURE_SUBSCRIPTION_ID
$tenant = '00000000-0000-0000-0000-000000000004'
try {
    foreach ($scenario in @('success', 'docker', 'user', 'subscription', 'service-principal',
        'arm-token', 'malformed-token', 'missing-oid', 'wrong-tenant',
        'preferred-name', 'unique-name', 'missing-name')) {
        $state = @{ Failure = $scenario; Values = @{} }
        $env:AZURE_SUBSCRIPTION_ID = if ($scenario -eq 'subscription') { '' } else { $subscription }
        $failure = $null
        $output = ''
        try {
            $output = & (Join-Path $root 'scripts\Prepare-Database.ps1') 6>&1 | Out-String
        } catch { $failure = $_.Exception.Message }
        Assert-True ($output -notmatch 'synthetic-sensitive-token' -and
            $failure -notmatch 'synthetic-sensitive-token') "$scenario disclosed an ARM token."
        if ($scenario -in @('success', 'preferred-name', 'unique-name')) {
            Assert-True ($null -eq $failure -and $state.Values.Count -eq 2) "Preflight failed: $failure"
            Assert-True ($state.Values.DATABASE_ADMIN_NAME -ceq 'admin@example.invalid') 'Wrong administrator name.'
            Assert-True ($state.Values.DATABASE_ADMIN_OBJECT_ID -ceq '00000000-0000-0000-0000-000000000003') `
                'Wrong administrator object ID.'
        } else {
            Assert-True ($null -ne $failure -and $state.Values.Count -eq 0) "$scenario must fail without changing azd values."
        }
    }
} finally {
    $env:AZURE_SUBSCRIPTION_ID = $originalSubscription
}
Write-Host 'Twelve administrator-preflight scenarios passed, including token-based names, tenant validation, and token non-disclosure.'
