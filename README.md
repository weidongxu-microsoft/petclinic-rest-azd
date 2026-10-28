# Petclinic REST on Azure

A standalone azd template for Spring Petclinic REST on Azure Container Apps,
PostgreSQL or MySQL Flexible Server, and Key Vault. No azd extension is required.

## Deploy

Install [azd](https://aka.ms/azd-install), Azure CLI, Docker, and PowerShell 7.
Start Docker and sign in using browser authentication:

```sh
az login
azd auth login
azd init -t weidongxu-microsoft/petclinic-rest-azd
azd up
```

Choose an environment, subscription, location, database engine, and database size.
PostgreSQL and `small` are the initial selections.

| Choice | Small | Larger |
|---|---|---|
| Database compute | B1ms: 1 vCore, 2 GiB RAM | B2s: 2 vCores, 4 GiB RAM |
| Database storage | 32 GiB | 32 GiB |
| Cost | Recommended for this demo | Higher compute cost; not a production tier |

Versions are fixed to PostgreSQL 16 and MySQL 8.4 LTS. Regional SKU availability and
subscription quota still apply. Use a new azd environment to change engines:
this template does not migrate data or remove the previous engine's resources.

For automation, set `DATABASE_ENGINE` (`postgresql` or `mysql`) and `DATABASE_SIZE`
(`small` or `larger`) with `azd env set` before provisioning. Without explicit
values, `--no-prompt` selects PostgreSQL and small; saved selections are reused.

Database credentials are generated automatically and reused from the local azd environment
on subsequent provisions. There is no API password prompt.

The deploying identity needs resource creation permissions and permission to
create role assignments, such as Contributor plus Role Based Access Control
Administrator on the deployment scope. The database hook uses your Azure CLI
login to start and observe a Container Apps job.

Provisioning initializes the database through that isolated job before deploying
the application. Only the job receives the administrator credential. The app
uses a separate database login with data-access permissions, not schema creation
or role-management permissions. Existing data is not reseeded on reprovision.

## Call the API

Use the HTTPS endpoint printed by azd:

```sh
curl "https://<app-host>/petclinic/api/vets"
```

The API is public and unauthenticated, preserving upstream's default behavior.
Do not use it for sensitive data. Azure runs the existing `postgres` or `mysql`
profile with `spring-data-jpa`. Deployment-only settings in `deployment/spring-configuration.json`
are injected using `SPRING_APPLICATION_JSON`; no application files are modified.
Upstream returns HTTP `500` for missing routes, including disabled Swagger and H2
routes, rather than `404`.

## Security and boundaries

- HTTPS-only ingress; the bootstrap image has no public ingress.
- Both databases require TLS; the app validates the server certificate and hostname.
- The database and Key Vault deny other network clients, allowing only the app's
  reported outbound IPs. There is no "allow all Azure services" firewall rule.
- Managed identities pull images and read individually scoped Key Vault secrets.
  The app cannot read the database administrator secret.
- The application container runs as a non-root user. Swagger and the H2 console
  are disabled by deployment configuration.
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
Appropriate purge permission is required. The database, app, registry, logs,
Key Vault operations, and initialization job executions incur Azure charges.

## Local checks and upstream source

```sh
mvn --batch-mode --no-transfer-progress verify
az bicep build --file infra/main.bicep
docker build --tag petclinic-rest:test .
pwsh -File tests/Test-DatabaseInitialization.ps1 -ApplicationImage petclinic-rest:test
pwsh -File tests/Test-DatabaseInitialization.ps1 -DatabaseEngine mysql -ApplicationImage petclinic-rest:test
```

`src/` and `pom.xml` are unchanged from upstream commit
[`afc8fc1`](https://github.com/spring-petclinic/spring-petclinic-rest/tree/afc8fc1d3b8ec8de69414482b3bd70a1da78cb95).
See [UPSTREAM.md](UPSTREAM.md), [NOTICE](NOTICE), and [LICENSE.txt](LICENSE.txt).
