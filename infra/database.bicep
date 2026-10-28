param location string
@allowed(['postgresql', 'mysql'])
param engine string
@allowed(['small', 'larger'])
param size string
@secure()
param administratorPassword string
@minLength(1)
param outboundIps array

var skuName = size == 'small' ? 'Standard_B1ms' : 'Standard_B2s'

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = if (engine == 'postgresql') {
  name: 'pg-petclinic-${uniqueString(resourceGroup().id)}'
  location: location
  sku: { name: skuName, tier: 'Burstable' }
  properties: {
    version: '16'
    administratorLogin: 'azdadmin'
    administratorLoginPassword: administratorPassword
    authConfig: { passwordAuth: 'Enabled', activeDirectoryAuth: 'Disabled' }
    storage: { storageSizeGB: 32, autoGrow: 'Enabled' }
    backup: { backupRetentionDays: 7, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: 'Disabled' }
    network: { publicNetworkAccess: 'Enabled' }
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = if (engine == 'postgresql') {
  parent: server
  name: 'petclinic'
  properties: { charset: 'UTF8', collation: 'en_US.utf8' }
}

resource requireTls 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = if (engine == 'postgresql') {
  parent: server
  name: 'require_secure_transport'
  properties: { value: 'on', source: 'user-override' }
}

resource firewall 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = [
  for ip in union(outboundIps, []): if (engine == 'postgresql') {
    parent: server
    name: 'aca-${replace(ip, '.', '-')}'
    properties: { startIpAddress: ip, endIpAddress: ip }
  }
]

resource mysql 'Microsoft.DBforMySQL/flexibleServers@2024-12-30' = if (engine == 'mysql') {
  name: 'mysql-petclinic-${uniqueString(resourceGroup().id)}'
  location: location
  sku: { name: skuName, tier: 'Burstable' }
  properties: {
    version: '8.4'
    administratorLogin: 'azdadmin'
    administratorLoginPassword: administratorPassword
    storage: { storageSizeGB: 32, autoGrow: 'Enabled' }
    backup: { backupRetentionDays: 7, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: 'Disabled' }
    network: { publicNetworkAccess: 'Enabled' }
  }
}

resource mysqlDatabase 'Microsoft.DBforMySQL/flexibleServers/databases@2024-12-30' = if (engine == 'mysql') {
  parent: mysql
  name: 'petclinic'
  properties: { charset: 'utf8mb4', collation: 'utf8mb4_unicode_ci' }
}

resource mysqlRequireTls 'Microsoft.DBforMySQL/flexibleServers/configurations@2024-12-30' = if (engine == 'mysql') {
  parent: mysql
  name: 'require_secure_transport'
  properties: { value: 'ON', source: 'user-override' }
}

resource mysqlTlsVersion 'Microsoft.DBforMySQL/flexibleServers/configurations@2024-12-30' = if (engine == 'mysql') {
  parent: mysql
  name: 'tls_version'
  properties: { value: 'TLSv1.2,TLSv1.3', source: 'user-override' }
}

resource mysqlFirewall 'Microsoft.DBforMySQL/flexibleServers/firewallRules@2024-12-30' = [
  for ip in union(outboundIps, []): if (engine == 'mysql') {
    parent: mysql
    name: 'aca-${replace(ip, '.', '-')}'
    properties: { startIpAddress: ip, endIpAddress: ip }
  }
]

output host string = engine == 'postgresql'
  ? server!.properties.fullyQualifiedDomainName
  : mysql!.properties.fullyQualifiedDomainName
