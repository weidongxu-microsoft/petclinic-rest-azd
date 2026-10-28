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
