-- 1. Dedicated Application User (Used by Backend Container App)
CREATE USER IF NOT EXISTS 'ewaste_app_user'@'%' IDENTIFIED BY 'StrongAppPassword123!';
GRANT SELECT, INSERT, UPDATE, DELETE ON ewastedb.* TO 'ewaste_app_user'@'%';

-- 2. Read-Only Developer/Analyst User (Used by PyCharm or Data Analytics)
CREATE USER IF NOT EXISTS 'ewaste_dev_ro'@'%' IDENTIFIED BY 'StrongDevPassword123!';
GRANT SELECT, SHOW VIEW ON ewastedb.* TO 'ewaste_dev_ro'@'%';

-- 3. Schema Migration User (Used by Liquibase CI/CD job only)
CREATE USER IF NOT EXISTS 'ewaste_migrator'@'%' IDENTIFIED BY 'StrongMigratorPassword123!';
GRANT ALL PRIVILEGES ON ewastedb.* TO 'ewaste_migrator'@'%';

FLUSH PRIVILEGES;