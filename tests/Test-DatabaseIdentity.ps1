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
    $state.IpCalls++
    Assert-True ($Uri -eq 'https://api.ipify.org' -and $TimeoutSec -eq 15) 'Unexpected IP discovery request.'
    return $state.Ip
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
    $rule = Get-Argument $arguments '--name'
    Assert-True ($rule -match '^petclinic-bootstrap-[a-f0-9]{32}$') 'Only the owned temporary rule may be changed.'
    if ($arguments[3] -eq 'create') {
        $state.Created = $rule
        Assert-True ((Get-Argument $arguments '--start-ip-address') -eq '203.0.113.1' -and
            (Get-Argument $arguments '--end-ip-address') -eq '203.0.113.1') 'Bootstrap must allow only the client IPv4.'
        if ($state.Failure -eq 'create') { $global:LASTEXITCODE = 1 }
    } else {
        Assert-True ($arguments[3] -eq 'delete' -and $rule -ceq $state.Created) 'Cleanup must target the exact created rule.'
        $state.Deleted = $rule
        if ($state.Failure -eq 'delete') { $global:LASTEXITCODE = 1 }
    }
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
    foreach ($scenario in @('success', 'token', 'create', 'sql', 'delete', 'ip', 'host')) {
        $state = @{
            Failure = $scenario
            Ip = if ($scenario -eq 'ip') { 'invalid' } else { '203.0.113.1' }
            IpCalls = 0; TokenCalls = 0; DockerCalls = 0; Created = ''; Deleted = ''
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
        if ($scenario -eq 'success') {
            Assert-True ($null -eq $failure -and $state.DockerCalls -eq 1) "Successful setup failed: $failure"
        } else {
            Assert-True ($null -ne $failure) "$scenario should fail."
        }
        if ($scenario -in @('success', 'create', 'sql', 'delete')) {
            Assert-True ($state.Created -ne '' -and $state.Created -ceq $state.Deleted) "$scenario must attempt firewall cleanup."
        } else {
            Assert-True ($state.Created -eq '' -and $state.DockerCalls -eq 0) "$scenario mutated Azure or executed SQL."
        }
        if ($scenario -eq 'host') {
            Assert-True ($state.IpCalls -eq 0 -and $state.TokenCalls -eq 0) 'Invalid host must fail before network access.'
        }
    }
} finally {
    $env:PGPASSWORD = $originalPassword
}
Write-Host 'Seven identity-bootstrap scenarios passed, including failure cleanup, verified TLS, and token non-disclosure.'

function docker {
    Assert-True (($args -join ' ') -eq 'info --format {{.ServerVersion}}') 'Unexpected preflight Docker command.'
    $global:LASTEXITCODE = if ($state.Failure -eq 'docker') { 1 } else { 0 }
}
function az {
    Assert-True (($args[0..2] -join ' ') -eq 'ad signed-in-user show') 'Preflight must inspect the signed-in user.'
    Assert-True ((Get-Argument $args '--subscription') -eq $subscription) 'Preflight must use the selected subscription.'
    $global:LASTEXITCODE = if ($state.Failure -eq 'user') { 1 } else { 0 }
    return '{"id":"00000000-0000-0000-0000-000000000003","userPrincipalName":"admin@example.invalid"}'
}
function azd {
    Assert-True (($args[0..1] -join ' ') -eq 'env set') 'Only administrator metadata may be persisted.'
    Assert-True ($args[2] -in @('DATABASE_ADMIN_OBJECT_ID', 'DATABASE_ADMIN_NAME')) 'Do not persist credentials.'
    $state.Values[$args[2]] = $args[3]
    $global:LASTEXITCODE = 0
}
$originalSubscription = $env:AZURE_SUBSCRIPTION_ID
try {
    foreach ($scenario in @('success', 'docker', 'user', 'subscription')) {
        $state = @{ Failure = $scenario; Values = @{} }
        $env:AZURE_SUBSCRIPTION_ID = if ($scenario -eq 'subscription') { '' } else { $subscription }
        $failure = $null
        try { & (Join-Path $root 'scripts\Prepare-Database.ps1') } catch { $failure = $_.Exception.Message }
        if ($scenario -eq 'success') {
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
Write-Host 'Four administrator-preflight scenarios passed; only non-secret identity metadata is persisted.'
