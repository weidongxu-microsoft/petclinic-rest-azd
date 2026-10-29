$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (!$env:DATABASE_SERVER_ID -or !$env:DATABASE_OUTBOUND_IPS) {
    throw 'Missing azd provisioning outputs for the database firewall.'
}
$outboundIps = ConvertFrom-Json -InputObject $env:DATABASE_OUTBOUND_IPS -NoEnumerate
if ($outboundIps -isnot [array] -or $outboundIps.Count -eq 0 -or
    @($outboundIps | Where-Object { $_ -isnot [string] }).Count -ne 0) {
    throw 'DATABASE_OUTBOUND_IPS must contain a nonempty JSON array of IPv4 addresses.'
}
. (Join-Path $PSScriptRoot 'Sync-DatabaseFirewall.ps1')
Sync-DatabaseFirewall -ServerId $env:DATABASE_SERVER_ID -OutboundIps $outboundIps
