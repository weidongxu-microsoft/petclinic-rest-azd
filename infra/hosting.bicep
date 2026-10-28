param location string

var token = uniqueString(resourceGroup().id)

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acrpetclinic${token}'
  location: location
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

resource applicationIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-petclinic-${token}'
  location: location
}

resource initializerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-petclinic-init-${token}'
  location: location
}

resource pull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, applicationIdentity.id, 'AcrPull')
  properties: {
    principalId: applicationIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    )
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-petclinic-${token}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-petclinic-${token}'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspace.properties.customerId
        sharedKey: workspace.listKeys().primarySharedKey
      }
    }
  }
}

output registryEndpoint string = registry.properties.loginServer
output environmentId string = environment.id
output applicationIdentityId string = applicationIdentity.id
output applicationPrincipalId string = applicationIdentity.properties.principalId
output initializerIdentityId string = initializerIdentity.id
output initializerPrincipalId string = initializerIdentity.properties.principalId
