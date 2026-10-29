\set ON_ERROR_STOP on
BEGIN;
SELECT pg_advisory_xact_lock(73642102);
SELECT set_config('petclinic.application_oid', :'application_oid', true);
DO $bootstrap$
DECLARE
    mapping record;
BEGIN
    SELECT objectid, isadmin INTO mapping
      FROM pg_catalog.pgaadauth_list_principals(false)
      WHERE rolname = 'petclinic_app';
    IF FOUND THEN
        IF mapping.objectid::uuid IS DISTINCT FROM current_setting('petclinic.application_oid')::uuid
           OR mapping.isadmin IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'petclinic_app is mapped to a different identity or is an Entra administrator';
        END IF;
    ELSIF EXISTS (SELECT FROM pg_roles WHERE rolname = 'petclinic_app') THEN
        RAISE EXCEPTION 'petclinic_app already exists without the expected Entra mapping';
    ELSE
        PERFORM pg_catalog.pgaadauth_create_principal_with_oid(
            'petclinic_app', current_setting('petclinic.application_oid'), 'service', false, false);
    END IF;
    IF EXISTS (
        SELECT FROM pg_roles
        WHERE (rolname = 'petclinic_app' OR pg_has_role('petclinic_app', oid, 'MEMBER'))
          AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
    ) OR pg_has_role('petclinic_app', 'azure_pg_admin', 'MEMBER') THEN
        RAISE EXCEPTION 'petclinic_app must not have administrator privileges';
    END IF;
END
$bootstrap$;
GRANT CONNECT ON DATABASE petclinic TO petclinic_app;
COMMIT;

\connect petclinic
BEGIN;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO petclinic_app;
COMMIT;
