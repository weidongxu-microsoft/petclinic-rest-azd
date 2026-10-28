targetScope = 'subscription'

@minLength(1)
@maxLength(64)
param environmentName string
param location string

@secure()
@metadata({
  azd: {
    type: 'generate'
    config: { length: 32, minLower: 1, minUpper: 1, minNumeric: 1, minSpecial: 1 }
  }
})
param databaseAdministratorPassword string

@secure()
@metadata({
  azd: {
    type: 'generate'
    config: { length: 32, minLower: 1, minUpper: 1, minNumeric: 1, minSpecial: 1 }
  }
})
param databasePassword string

@secure()
@minLength(16)
@maxLength(72)
@description('Choose an API password (16-72 ASCII characters) for HTTP Basic user petclinic. Do not reuse another password.')
param apiPassword string

var serviceName = 'spring-petclinic-rest-app'

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: { 'azd-env-name': environmentName }
}

module hosting 'hosting.bicep' = {
  name: 'hosting'
  scope: group
  params: { location: location }
}

module bootstrap 'bootstrap.bicep' = {
  name: 'bootstrap'
  scope: group
  params: {
    location: location
    serviceName: serviceName
    environmentId: hosting.outputs.environmentId
    identityId: hosting.outputs.applicationIdentityId
  }
}

module database 'database.bicep' = {
  name: 'database'
  scope: group
  params: {
    location: location
    administratorPassword: databaseAdministratorPassword
    outboundIps: bootstrap.outputs.outboundIps
  }
}

module secrets 'secrets.bicep' = {
  name: 'secrets'
  scope: group
  params: {
    location: location
    administratorPassword: databaseAdministratorPassword
    databasePassword: databasePassword
    apiPassword: apiPassword
    applicationPrincipalId: hosting.outputs.applicationPrincipalId
    initializerPrincipalId: hosting.outputs.initializerPrincipalId
    outboundIps: bootstrap.outputs.outboundIps
  }
}

module initializer 'database-init.bicep' = {
  name: 'database-init'
  scope: group
  params: {
    location: location
    environmentId: hosting.outputs.environmentId
    identityId: hosting.outputs.initializerIdentityId
    databaseHost: database.outputs.host
    vaultUri: secrets.outputs.vaultUri
  }
}

module application 'application.bicep' = {
  name: 'application'
  scope: group
  params: {
    location: location
    serviceName: serviceName
    environmentId: hosting.outputs.environmentId
    identityId: hosting.outputs.applicationIdentityId
    registryEndpoint: hosting.outputs.registryEndpoint
    databaseHost: database.outputs.host
    vaultUri: secrets.outputs.vaultUri
    appImage: bootstrap.outputs.image
  }
}

output AZURE_RESOURCE_GROUP string = group.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = hosting.outputs.registryEndpoint
output CONTAINER_APP_ENVIRONMENT_ID string = hosting.outputs.environmentId
output APPLICATION_IDENTITY_ID string = hosting.outputs.applicationIdentityId
output DATABASE_HOST string = database.outputs.host
output DATABASE_INIT_JOB_NAME string = initializer.outputs.name
output KEY_VAULT_NAME string = secrets.outputs.vaultName
output KEY_VAULT_URI string = secrets.outputs.vaultUri
output SERVICE_SPRING_PETCLINIC_REST_APP_ENDPOINT_URL string = application.outputs.SERVICE_SPRING_PETCLINIC_REST_APP_ENDPOINT_URL
