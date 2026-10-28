# Petclinic REST on Azure

A standalone azd template for Spring Petclinic REST on Azure Container Apps,
PostgreSQL Flexible Server, and Key Vault. No azd extension is required.

## Deploy

Install [azd](https://aka.ms/azd-install), Azure CLI, Docker, and PowerShell 7.
Start Docker and sign in using browser authentication:

```sh
az login
azd auth login
azd init -t weidongxu-microsoft/petclinic-rest-azd
azd up
```

Choose an environment, subscription, location, and a unique API password when
prompted. Use 16-72 ASCII characters; BCrypt accepts at most 72 UTF-8 bytes.
The API username is `petclinic`. Database credentials are generated automatically
and reused from the local azd environment on subsequent provisions.

The deploying identity needs resource creation permissions and permission to
create role assignments, such as Contributor plus Role Based Access Control
Administrator on the deployment scope. The database hook uses your Azure CLI
login to start and observe a Container Apps job.

Provisioning initializes the database through that isolated job before deploying
the application. Only the job receives the administrator credential. The app
uses a separate database login with data-access permissions, not schema creation
or role-management permissions. Existing data is not reseeded on reprovision.

## Call the API

Use the HTTPS endpoint printed by azd. This command prompts for your API password
instead of including it in shell history:

```sh
curl --user petclinic "https://<app-host>/petclinic/api/vets"
```

Missing or incorrect credentials return `401`. All application endpoints,
including actuator health, require authentication; platform probes use TCP.
The upstream sample administrator is disabled. Local upstream profiles retain
their original behavior; Azure runs `postgres,spring-data-jpa,azure`.

## Security and boundaries

- HTTPS-only ingress; the bootstrap image has no public ingress.
- PostgreSQL requires TLS; the app validates the server certificate and hostname.
- PostgreSQL and Key Vault deny other network clients, allowing only the app's
  reported outbound IPs. There is no "allow all Azure services" firewall rule.
- Managed identities pull images and read individually scoped Key Vault secrets.
  The app cannot read the database administrator or API password secrets.
- The API password is stored in Key Vault and used by initialization to create a
  BCrypt hash in Petclinic's existing users table. No new Java authentication code.
- The application container runs as a non-root user. Swagger and the H2 console
  are disabled in the Azure profile.
- Secure deployment parameters remain in azd's local environment configuration.
  Do not commit `.azure/` or publish its contents.

This is a demo baseline, not a production reference architecture. No private
endpoints or fixed-egress NAT gateway are configured. Outbound IPs can change;
reprovision to refresh allowlists. Shared egress IPs are not workload isolation:
database authentication and Key Vault RBAC remain required. RBAC propagation can
delay the first secret resolution; inspect failures before retrying provision.

Key Vault has mandatory soft delete, seven-day retention, and purge protection
disabled for disposable testing. Organizational policies may require different
settings. A deleted vault reserves its globally unique name until purged.

## Clean up

```sh
azd down --purge
```

This permanently removes the template's resources and purges the vault.
Appropriate purge permission is required. PostgreSQL, the app, registry, logs,
Key Vault operations, and initialization job executions incur Azure charges.

## Local checks and upstream source

```sh
mvn --batch-mode --no-transfer-progress verify
az bicep build --file infra/main.bicep
docker build --tag petclinic-rest:test .
pwsh -File tests/Test-DatabaseInitialization.ps1 -ApplicationImage petclinic-rest:test
```

Application source is pinned to upstream commit
[`afc8fc1`](https://github.com/spring-petclinic/spring-petclinic-rest/tree/afc8fc1d3b8ec8de69414482b3bd70a1da78cb95).
See [UPSTREAM.md](UPSTREAM.md), [NOTICE](NOTICE), and [LICENSE.txt](LICENSE.txt).
