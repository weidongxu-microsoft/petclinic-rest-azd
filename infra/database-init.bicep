param location string
param environmentId string
param identityId string
param databaseHost string
param vaultUri string

var script = '''
set -eu
psql -X --set=ON_ERROR_STOP=1 --dbname=postgres <<'SQL'
SELECT pg_advisory_lock(73642101);
\getenv application_password APPLICATION_PASSWORD
SELECT 'CREATE ROLE petclinic LOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'petclinic') \gexec
ALTER ROLE petclinic PASSWORD :'application_password';
REVOKE ALL ON DATABASE petclinic FROM PUBLIC;
GRANT CONNECT ON DATABASE petclinic TO petclinic;
SQL
psql -X --set=ON_ERROR_STOP=1 --single-transaction --dbname=petclinic <<'SQL'
SELECT pg_advisory_xact_lock(73642102);
CREATE TABLE IF NOT EXISTS azd_template_migrations (version integer PRIMARY KEY);
SELECT NOT EXISTS (SELECT FROM azd_template_migrations WHERE version = 1) AS initialize \gset
\if :initialize
__SCHEMA__
__DATA__
INSERT INTO azd_template_migrations VALUES (1);
\endif
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO petclinic;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO petclinic;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO petclinic;
REVOKE ALL ON azd_template_migrations FROM petclinic;
SQL
'''
var initialization = replace(
  replace(script, '__SCHEMA__', loadTextContent('../src/main/resources/db/postgres/schema.sql')),
  '__DATA__',
  loadTextContent('../src/main/resources/db/postgres/data.sql')
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
          image: 'postgres:16-bookworm'
          command: ['/bin/sh', '-ec', initialization]
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'PGHOST', value: databaseHost }
            { name: 'PGUSER', value: 'azdadmin' }
            { name: 'PGPASSWORD', secretRef: 'administrator-password' }
            { name: 'APPLICATION_PASSWORD', secretRef: 'database-password' }
            { name: 'PGSSLMODE', value: 'verify-full' }
            { name: 'PGSSLROOTCERT', value: '/etc/ssl/certs/ca-certificates.crt' }
          ]
        }
      ]
    }
  }
}

output name string = job.name
