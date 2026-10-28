set -eu
application_password_hex=$(printf '%s' "$APPLICATION_PASSWORD" | od -An -v -tx1 | tr -d ' \n')
mysql --host="$MYSQL_HOST" --user="$MYSQL_USER" \
  --ssl-mode="$MYSQL_SSL_MODE" --ssl-ca="$MYSQL_SSL_CA" \
  --database=petclinic --batch <<SQL
SET @application_password = CONVERT(UNHEX('$application_password_hex') USING utf8mb4);
SET @create_user = CONCAT('CREATE USER IF NOT EXISTS ''petclinic''@''%'' IDENTIFIED BY ', QUOTE(@application_password), ' REQUIRE SSL');
PREPARE statement FROM @create_user;
EXECUTE statement;
DEALLOCATE PREPARE statement;
SET @alter_user = CONCAT('ALTER USER ''petclinic''@''%'' IDENTIFIED BY ', QUOTE(@application_password), ' REQUIRE SSL');
PREPARE statement FROM @alter_user;
EXECUTE statement;
DEALLOCATE PREPARE statement;
SQL
mysql --host="$MYSQL_HOST" --user="$MYSQL_USER" \
  --ssl-mode="$MYSQL_SSL_MODE" --ssl-ca="$MYSQL_SSL_CA" \
  --database=petclinic --batch <<'SQL'
DELIMITER //
CREATE PROCEDURE IF NOT EXISTS azd_initialize_petclinic_v1()
SQL SECURITY INVOKER
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    DO RELEASE_LOCK('petclinic-azd-initialize');
    RESIGNAL;
  END;
  IF IFNULL(GET_LOCK('petclinic-azd-initialize', 60), 0) <> 1 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Could not acquire database initialization lock';
  END IF;
  CREATE TABLE IF NOT EXISTS azd_template_migrations (version INT NOT NULL PRIMARY KEY);
  IF NOT EXISTS (SELECT 1 FROM azd_template_migrations WHERE version = 1) THEN
__SCHEMA__
__DATA__
    INSERT INTO azd_template_migrations VALUES (1);
  END IF;
  DO RELEASE_LOCK('petclinic-azd-initialize');
END//
DELIMITER ;
CALL azd_initialize_petclinic_v1();
GRANT SELECT, INSERT, UPDATE, DELETE ON petclinic.vets TO 'petclinic'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON petclinic.specialties TO 'petclinic'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON petclinic.vet_specialties TO 'petclinic'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON petclinic.types TO 'petclinic'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON petclinic.owners TO 'petclinic'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON petclinic.pets TO 'petclinic'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON petclinic.visits TO 'petclinic'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON petclinic.users TO 'petclinic'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON petclinic.roles TO 'petclinic'@'%';
SQL
