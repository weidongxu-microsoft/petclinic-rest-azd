$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\Sync-DatabaseFirewall.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) {
        throw $Message
    }
}

function New-Rule {
    param([string]$Ip, [string]$Name)
    if (!$Name) {
        $Name = "aca-$($Ip.Replace('.', '-'))"
    }
    return @{ name = $Name; startIpAddress = $Ip; endIpAddress = $Ip }
}

function Get-Argument {
    param([string[]]$Arguments, [string]$Name)
    $index = [Array]::IndexOf($Arguments, $Name)
    Assert-True ($index -ge 0 -and $index + 1 -lt $Arguments.Count) "Missing CLI argument $Name."
    return $Arguments[$index + 1]
}

function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    $state.CallCount++
    Assert-True (($arguments[0..2] -join ' ') -eq "$($state.Engine) flexible-server firewall-rule") `
        'Unexpected Azure CLI command.'
    Assert-True ((Get-Argument $arguments '--subscription') -eq $state.Subscription) 'Wrong subscription.'
    Assert-True ((Get-Argument $arguments '--resource-group') -eq 'test-group') 'Wrong resource group.'
    $serverFlag = if ($state.Engine -eq 'postgres') { '--server-name' } else { '--name' }
    Assert-True ((Get-Argument $arguments $serverFlag) -eq 'test-server') 'Wrong database server.'
    Assert-True ($arguments -contains '--only-show-errors') 'CLI warnings must not corrupt JSON output.'

    if ($arguments[3] -eq 'list') {
        Assert-True ((Get-Argument $arguments '--output') -eq 'json') 'Expected JSON firewall listing.'
        $state.ListCount++
        if ($state.Case['ListFails'] -eq $state.ListCount) {
            $global:LASTEXITCODE = 1
            return
        }
        if ($state.Case.ContainsKey('ListJson')) {
            return $state.Case['ListJson']
        }
        return ConvertTo-Json -InputObject @($state.Rules) -Depth 5 -Compress
    }
    Assert-True ($arguments[3] -eq 'delete') 'Only list and delete are allowed.'
    Assert-True ($arguments -contains '--yes') 'Firewall deletion must not prompt.'
    Assert-True ((Get-Argument $arguments '--output') -eq 'none') 'Deletion must not emit data.'
    $ruleFlag = if ($state.Engine -eq 'postgres') { '--name' } else { '--rule-name' }
    $name = Get-Argument $arguments $ruleFlag
    $state.Deletes.Add($name)
    if ($state.Case['DeleteFails']) {
        $global:LASTEXITCODE = 1
        return
    }
    if (!$state.Case['RetainDeleted']) {
        $state.Rules = @($state.Rules | Where-Object { $_.name -cne $name })
    }
}

$a = '203.0.113.1'
$b = '203.0.113.2'
$c = '203.0.113.3'
$cases = @(
    @{ Name = 'unchanged'; Ips = @($a); Rules = @((New-Rule $a)); Deletes = @() },
    @{ Name = 'duplicate desired IPs'; Ips = @($a, $a); Rules = @((New-Rule $a)); Deletes = @() },
    @{ Name = 'IP replacement'; Ips = @($b); Rules = @((New-Rule $a), (New-Rule $b))
        Deletes = @('aca-203-0-113-1') },
    @{ Name = 'shrinking IP set'; Ips = @($b); Rules = @((New-Rule $a), (New-Rule $b), (New-Rule $c))
        Deletes = @('aca-203-0-113-1', 'aca-203-0-113-3') },
    @{ Name = 'unrelated rules'; Ips = @($b)
        Rules = @((New-Rule $a), (New-Rule $b), (New-Rule $c 'office'),
            (New-Rule $c 'aca-custom'), (New-Rule $c 'aca-203-0-113-3-backup'))
        Deletes = @('aca-203-0-113-1') },
    @{ Name = 'empty IP list'; Ips = @(); Rules = @((New-Rule $a)); Deletes = @()
        Error = 'null, empty'; Calls = 0 },
    @{ Name = 'invalid IP'; Ips = @('invalid'); Rules = @((New-Rule $a)); Deletes = @()
        Error = 'canonical IPv4'; Calls = 0 },
    @{ Name = 'IPv6'; Ips = @('2001:db8::1'); Rules = @((New-Rule $a)); Deletes = @()
        Error = 'canonical IPv4'; Calls = 0 },
    @{ Name = 'noncanonical IP'; Ips = @('127.1'); Rules = @((New-Rule $a)); Deletes = @()
        Error = 'canonical IPv4'; Calls = 0 },
    @{ Name = 'missing current rule'; Ips = @($b); Rules = @((New-Rule $a)); Deletes = @()
        Error = 'Required firewall rule.*missing' },
    @{ Name = 'empty firewall'; Ips = @($b); Rules = @(); Deletes = @()
        Error = 'Required firewall rule.*missing' },
    @{ Name = 'initial list failure'; Ips = @($b); Rules = @((New-Rule $a), (New-Rule $b))
        Deletes = @(); ListFails = 1; Error = 'Could not list' },
    @{ Name = 'malformed JSON'; Ips = @($b); Rules = @(); Deletes = @()
        ListJson = 'not JSON'; Error = 'JSON' },
    @{ Name = 'non-array JSON'; Ips = @($b); Rules = @(); Deletes = @()
        ListJson = '{}'; Error = 'must be a JSON array' },
    @{ Name = 'null JSON'; Ips = @($b); Rules = @(); Deletes = @()
        ListJson = 'null'; Error = 'must be a JSON array' },
    @{ Name = 'invalid rule'; Ips = @($b); Rules = @('unexpected'); Deletes = @()
        Error = 'invalid rule' },
    @{ Name = 'changed reserved range'; Ips = @($b)
        Rules = @((New-Rule $c 'aca-203-0-113-1'), (New-Rule $b)); Deletes = @()
        Error = 'unexpected address range' },
    @{ Name = 'duplicate listed rule'; Ips = @($b); Rules = @((New-Rule $a), (New-Rule $b), (New-Rule $b))
        Deletes = @(); Error = 'duplicate rule' },
    @{ Name = 'delete failure'; Ips = @($b); Rules = @((New-Rule $a), (New-Rule $b))
        Deletes = @('aca-203-0-113-1'); DeleteFails = $true; Error = 'Could not delete obsolete' },
    @{ Name = 'verification mismatch'; Ips = @($b); Rules = @((New-Rule $a), (New-Rule $b))
        Deletes = @('aca-203-0-113-1'); RetainDeleted = $true; Error = 'do not match' },
    @{ Name = 'verification list failure'; Ips = @($b); Rules = @((New-Rule $a), (New-Rule $b))
        Deletes = @('aca-203-0-113-1'); ListFails = 2; Error = 'Could not list' }
)

$subscription = '00000000-0000-0000-0000-000000000001'
$state = @{
    Subscription = $subscription
    Engine = $null
    Case = @{}
    Rules = @()
    Deletes = [Collections.Generic.List[string]]::new()
    CallCount = 0
    ListCount = 0
}
$count = 0
foreach ($engineName in @('postgres')) {
    $state.Engine = $engineName
    $provider = if ($engineName -eq 'postgres') { 'PostgreSQL' } else { 'MySQL' }
    $serverId = "/subscriptions/$subscription/resourceGroups/test-group/" +
        "providers/Microsoft.DBfor$provider/flexibleServers/test-server"
    foreach ($scenario in $cases) {
        $state.Case = $scenario
        $state.Rules = @($scenario.Rules | ForEach-Object { $_ })
        $state.Deletes = [Collections.Generic.List[string]]::new()
        $state.CallCount = 0
        $state.ListCount = 0
        $failure = $null
        try {
            Sync-DatabaseFirewall -ServerId $serverId -OutboundIps $scenario.Ips
        } catch {
            $failure = $_.Exception.Message
        }
        $context = "$engineName / $($scenario.Name)"
        if ($scenario['Error']) {
            Assert-True ($null -ne $failure -and $failure -match $scenario.Error) `
                "$context expected '$($scenario.Error)', received '$failure'."
        } else {
            Assert-True ($null -eq $failure) "$context failed: $failure"
            Assert-True ($state.ListCount -eq 2) "$context did not verify final firewall state."
            $unrelatedBefore = @($scenario.Rules | Where-Object { $_.name -notmatch '^aca-(?:[0-9]{1,3}-){3}[0-9]{1,3}$' })
            $unrelatedAfter = @($state.Rules | Where-Object { $_.name -notmatch '^aca-(?:[0-9]{1,3}-){3}[0-9]{1,3}$' })
            Assert-True (($unrelatedBefore | ConvertTo-Json -Depth 5) -ceq
                ($unrelatedAfter | ConvertTo-Json -Depth 5)) "$context modified unrelated rules."
        }
        Assert-True (($state.Deletes -join ',') -ceq ($scenario.Deletes -join ',')) "$context deleted unexpected rules."
        if ($scenario.ContainsKey('Calls')) {
            Assert-True ($state.CallCount -eq $scenario.Calls) "$context called Azure before validation."
        }
        $count++
    }
}

$state.CallCount = 0
$failure = $null
try {
    Sync-DatabaseFirewall -ServerId '/subscriptions/wrong/providers/Microsoft.Sql/servers/test' -OutboundIps @($a)
} catch {
    $failure = $_.Exception.Message
}
Assert-True ($failure -match 'Flexible Server resource ID' -and $state.CallCount -eq 0) `
    'Invalid database identity must fail before Azure calls.'

$environmentNames = @('DATABASE_SERVER_ID', 'DATABASE_OUTBOUND_IPS')
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$hookCount = 0
try {
    foreach ($engineName in @('postgres')) {
        $state.Engine = $engineName
        $provider = if ($engineName -eq 'postgres') { 'PostgreSQL' } else { 'MySQL' }
        $env:DATABASE_SERVER_ID = "/subscriptions/$subscription/resourceGroups/test-group/" +
            "providers/Microsoft.DBfor$provider/flexibleServers/test-server"
        $env:DATABASE_OUTBOUND_IPS = ConvertTo-Json -InputObject @($b) -Compress
        foreach ($deleteFails in @($false, $true)) {
            $state.Case = @{ DeleteFails = $deleteFails }
            $state.Rules = @((New-Rule $a), (New-Rule $b))
            $state.Deletes = [Collections.Generic.List[string]]::new()
            $state.CallCount = 0
            $state.ListCount = 0
            $failure = $null
            try {
                & (Join-Path $root 'scripts\Update-DatabaseFirewall.ps1')
            } catch {
                $failure = $_.Exception.Message
            }
            if ($deleteFails) {
                Assert-True ($failure -match 'Could not delete obsolete') `
                    "$engineName hook must propagate reconciliation failures."
            } else {
                Assert-True ($null -eq $failure -and $state.ListCount -eq 2) "$engineName hook failed: $failure"
            }
            $hookCount++
        }
    }
    foreach ($json in @('{}', '[]', '["invalid"]', '["203.0.113.1",123]', '')) {
        $env:DATABASE_OUTBOUND_IPS = $json
        $state.CallCount = 0
        $failure = $null
        try {
            & (Join-Path $root 'scripts\Update-DatabaseFirewall.ps1')
        } catch {
            $failure = $_.Exception.Message
        }
        Assert-True ($null -ne $failure -and $state.CallCount -eq 0) 'Invalid hook inputs must fail before Azure calls.'
        $hookCount++
    }
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
    }
}

$yaml = Get-Content -LiteralPath (Join-Path $root 'azure.yaml') -Raw
Assert-True ($yaml.Contains('run: scripts/Configure-Database.ps1') -and
    (Get-Content -LiteralPath (Join-Path $root 'scripts\Configure-Database.ps1') -Raw).
        Contains("'Update-DatabaseFirewall.ps1'")) `
    'The postprovision hook must reconcile the database firewall.'
$main = Get-Content -LiteralPath (Join-Path $root 'infra\main.bicep') -Raw
Assert-True ($main.Contains('output DATABASE_SERVER_ID string = database.outputs.serverId') -and
    $main.Contains('output DATABASE_OUTBOUND_IPS string = string(bootstrap.outputs.outboundIps)')) `
    'The hook must receive the selected database identity and the same outbound IPs used by Bicep.'

Write-Host "$count firewall scenarios and $hookCount hook scenarios passed, plus identity and wiring checks."
