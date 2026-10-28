param location string
@secure()
param administratorPassword string
@secure()
param databasePassword string
param applicationPrincipalId string
param initializerPrincipalId string
@minLength(1)
param outboundIps array

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-pc-${uniqueString(resourceGroup().id)}'
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    // Omit purge protection to keep its disabled default; the API rejects explicit false.
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
      ipRules: [for ip in union(outboundIps, []): { value: '${ip}/32' }]
    }
  }
}

resource administratorSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'database-administrator-password'
  properties: { value: administratorPassword }
}

resource databaseSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'database-password'
  properties: { value: databasePassword }
}

var secretReaderRole = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

resource applicationDatabaseAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: databaseSecret
  name: guid(databaseSecret.id, applicationPrincipalId, secretReaderRole)
  properties: {
    principalId: applicationPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: secretReaderRole
  }
}

resource initializerAdministratorAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: administratorSecret
  name: guid(administratorSecret.id, initializerPrincipalId, secretReaderRole)
  properties: {
    principalId: initializerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: secretReaderRole
  }
}

resource initializerDatabaseAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: databaseSecret
  name: guid(databaseSecret.id, initializerPrincipalId, secretReaderRole)
  properties: {
    principalId: initializerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: secretReaderRole
  }
}

output vaultName string = vault.name
output vaultUri string = vault.properties.vaultUri
