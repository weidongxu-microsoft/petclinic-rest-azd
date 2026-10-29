function Sync-DatabaseFirewall {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ServerId,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$OutboundIps
    )

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    $pattern = '^/subscriptions/([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})/resourceGroups/([^/]+)/providers/' +
        'Microsoft\.DBforPostgreSQL/flexibleServers/([^/]+)$'
    if ($ServerId -notmatch $pattern) {
        throw 'Expected a PostgreSQL Flexible Server resource ID from provisioning.'
    }
    $subscription = $Matches[1]
    $resourceGroup = $Matches[2]
    $engine = 'postgres'
    $serverName = $Matches[3]
    $scopeArguments = @('--subscription', $subscription, '--resource-group', $resourceGroup,
        '--server-name', $serverName, '--only-show-errors')

    $expected = @{}
    foreach ($ip in $OutboundIps) {
        $address = $null
        if (![Net.IPAddress]::TryParse($ip, [ref]$address) -or
            $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            $address.ToString() -cne $ip) {
            throw "Expected a canonical IPv4 outbound address, received '$ip'."
        }
        $expected["aca-$($ip.Replace('.', '-'))"] = $ip
    }

    function Get-TemplateFirewallRules {
        $arguments = @($engine, 'flexible-server', 'firewall-rule', 'list') +
            $scopeArguments + @('--output', 'json')
        $json = & az @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Could not list $engine firewall rules for $serverName."
        }
        $rules = ConvertFrom-Json -InputObject ($json -join "`n") -AsHashtable -NoEnumerate
        if ($rules -isnot [array]) {
            throw 'The database firewall list must be a JSON array.'
        }
        $owned = @{}
        foreach ($rule in $rules) {
            if ($rule -isnot [Collections.IDictionary] -or $rule['name'] -isnot [string]) {
                throw 'The database firewall list contains an invalid rule.'
            }
            $name = $rule['name']
            if ($name -cnotmatch '^aca-(?:[0-9]{1,3}-){3}[0-9]{1,3}$') {
                continue
            }
            $ip = $name.Substring(4).Replace('-', '.')
            $address = $null
            if (![Net.IPAddress]::TryParse($ip, [ref]$address) -or $address.ToString() -cne $ip -or
                $rule['startIpAddress'] -cne $ip -or $rule['endIpAddress'] -cne $ip) {
                throw "Template-reserved firewall rule '$name' has an unexpected address range."
            }
            if ($owned.ContainsKey($name)) {
                throw "The database firewall list contains duplicate rule '$name'."
            }
            $owned[$name] = $ip
        }
        return $owned
    }

    $current = Get-TemplateFirewallRules
    foreach ($name in $expected.Keys) {
        if (!$current.ContainsKey($name)) {
            throw "Required firewall rule '$name' is missing. Reprovision before removing obsolete rules."
        }
    }

    foreach ($name in @($current.Keys | Sort-Object)) {
        if ($expected.ContainsKey($name)) {
            continue
        }
        Write-Host "Removing obsolete template firewall rule $name."
        $arguments = @($engine, 'flexible-server', 'firewall-rule', 'delete') +
            $scopeArguments + @('--name', $name, '--yes', '--output', 'none')
        & az @arguments | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not delete obsolete firewall rule '$name'."
        }
    }

    $remaining = Get-TemplateFirewallRules
    if ($remaining.Count -ne $expected.Count -or
        @($expected.Keys | Where-Object { !$remaining.ContainsKey($_) }).Count -ne 0) {
        throw 'Template-owned database firewall rules do not match the provisioned outbound IPs.'
    }
    Write-Host 'Database firewall matches the provisioned outbound IPs; unrelated rules were preserved.'
}
