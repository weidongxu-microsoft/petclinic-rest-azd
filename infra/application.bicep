param location string
param serviceName string = 'spring-petclinic-rest-app'
param environmentId string
param identityId string
param registryEndpoint string
param databaseHost string
@allowed(['postgresql', 'mysql'])
param databaseEngine string
param vaultUri string
param appImage string

var placeholder = appImage == 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
var profile = databaseEngine == 'postgresql' ? 'postgres' : 'mysql'
var jdbcUrl = databaseEngine == 'postgresql'
  ? 'jdbc:postgresql://${databaseHost}:5432/petclinic?sslmode=verify-full&sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory'
  : 'jdbc:mysql://${databaseHost}:3306/petclinic?sslMode=VERIFY_IDENTITY&allowPublicKeyRetrieval=false'

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: serviceName
  location: location
  tags: { 'azd-service-name': serviceName }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      activeRevisionsMode: 'Single'
      // The bootstrap image must never become the public API.
      ingress: placeholder
        ? null
        : {
            external: true
            allowInsecure: false
            targetPort: 9966
            transport: 'http'
          }
      registries: [{ server: registryEndpoint, identity: identityId }]
      secrets: [
        { name: 'database-password', keyVaultUrl: '${vaultUri}secrets/database-password', identity: identityId }
      ]
    }
    template: {
      containers: [
        {
          name: 'app'
          image: appImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'SPRING_PROFILES_ACTIVE', value: '${profile},spring-data-jpa' }
            {
              name: 'SPRING_APPLICATION_JSON'
              value: string(loadJsonContent('../deployment/spring-configuration.json'))
            }
            {
              name: 'SPRING_DATASOURCE_URL'
              value: jdbcUrl
            }
            { name: 'SPRING_DATASOURCE_USERNAME', value: 'petclinic' }
            { name: 'SPRING_DATASOURCE_PASSWORD', secretRef: 'database-password' }
          ]
          probes: placeholder
            ? []
            : [
                {
                  type: 'Startup'
                  tcpSocket: { port: 9966 }
                  periodSeconds: 5
                  failureThreshold: 60
                }
                {
                  type: 'Readiness'
                  tcpSocket: { port: 9966 }
                  periodSeconds: 10
                  failureThreshold: 3
                }
              ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

output SERVICE_SPRING_PETCLINIC_REST_APP_ENDPOINT_URL string = placeholder
  ? ''
  : 'https://${app.properties.configuration.ingress.fqdn}/petclinic'
