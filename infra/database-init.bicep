param location string
param environmentId string
param identityId string
param databaseHost string
@allowed(['postgresql', 'mysql'])
param databaseEngine string
param vaultUri string

var images = {
  postgresql: 'postgres:16-alpine'
  mysql: 'mysql:8.4'
}
var certificates = {
  postgresql: '/etc/ssl/certs/ca-certificates.crt'
  mysql: '/etc/pki/tls/certs/ca-bundle.crt'
}
var script = databaseEngine == 'postgresql'
  ? loadTextContent('scripts/initialize-postgresql.sh')
  : loadTextContent('scripts/initialize-mysql.sh')
var schema = databaseEngine == 'postgresql'
  ? loadTextContent('../src/main/resources/db/postgres/schema.sql')
  : loadTextContent('../src/main/resources/db/mysql/schema.sql')
var data = databaseEngine == 'postgresql'
  ? loadTextContent('../src/main/resources/db/postgres/data.sql')
  : loadTextContent('../src/main/resources/db/mysql/data.sql')
var initialization = replace(
  replace(replace(script, '__SCHEMA__', schema), '__DATA__', data),
  '\r\n',
  '\n'
)

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: 'job-petclinic-init-${uniqueString(resourceGroup().id)}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    environmentId: environmentId
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 300
      replicaRetryLimit: 2
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
      secrets: [
        {
          name: 'administrator-password'
          keyVaultUrl: '${vaultUri}secrets/database-administrator-password'
          identity: identityId
        }
        { name: 'database-password', keyVaultUrl: '${vaultUri}secrets/database-password', identity: identityId }
      ]
    }
    template: {
      containers: [
        {
          name: 'initialize'
          image: images[databaseEngine]
          command: ['/bin/sh', '-ec', initialization]
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: databaseEngine == 'postgresql' ? [
            { name: 'PGHOST', value: databaseHost }
            { name: 'PGUSER', value: 'azdadmin' }
            { name: 'PGPASSWORD', secretRef: 'administrator-password' }
            { name: 'APPLICATION_PASSWORD', secretRef: 'database-password' }
            { name: 'PGSSLMODE', value: 'verify-full' }
            { name: 'PGSSLROOTCERT', value: certificates[databaseEngine] }
          ] : [
            { name: 'MYSQL_HOST', value: databaseHost }
            { name: 'MYSQL_USER', value: 'azdadmin' }
            { name: 'MYSQL_PWD', secretRef: 'administrator-password' }
            { name: 'APPLICATION_PASSWORD', secretRef: 'database-password' }
            { name: 'MYSQL_SSL_MODE', value: 'VERIFY_IDENTITY' }
            { name: 'MYSQL_SSL_CA', value: certificates[databaseEngine] }
          ]
        }
      ]
    }
  }
}

output name string = job.name
