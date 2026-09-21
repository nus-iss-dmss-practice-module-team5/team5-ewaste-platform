#!/usr/bin/env bash
# Self-contained persistence suite for migrations 001-025 (Sprint 1, C1, C2/C3, C4).
# Test SQL, fixtures, Go tests, contract expectations and Docker configuration are
# embedded below. No other test scripts, database/tests files or *_test.go files
# are read from the repository. Only production migrations, identity seeds,
# database/Dockerfile, and backend source/module files are inputs under test.
# Requires Bash, Git, Docker with Compose, and sha256sum or shasum.
# Run: ./scripts/test-persistence.sh
# PERSISTENCE_EVIDENCE_DIR optionally changes the parent of each fresh run folder.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v docker >/dev/null || { echo 'Docker with Compose is required.' >&2; exit 1; }
docker compose version >/dev/null
docker info >/dev/null
if command -v sha256sum >/dev/null; then HASH=(sha256sum); else HASH=(shasum -a 256); fi
EVIDENCE_ROOT="${PERSISTENCE_EVIDENCE_DIR:-$ROOT_DIR/artifacts/persistence}"
mkdir -p "$EVIDENCE_ROOT"
EVIDENCE_ROOT="$(cd "$EVIDENCE_ROOT" && pwd)"
RUN_DIR="$(mktemp -d "$EVIDENCE_ROOT/$(date -u +%Y%m%dt%H%M%Sz)-XXXXXX")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ewaste-persistence.XXXXXX")"
PROJECT="persistence-$(date -u +%Y%m%dt%H%M%Sz)-$$"
COMPOSE=(docker compose -p "$PROJECT" -f "$WORK_DIR/compose.yaml")
DOCKER_STARTED=0
finish() {
  local status=$?
  trap - EXIT
  if [[ "$DOCKER_STARTED" == 1 ]]; then
    if [[ "$status" != 0 ]]; then
      "${COMPOSE[@]}" logs --no-color mysql > "$RUN_DIR/mysql-failure.log" 2>&1 || true
    fi
    if ! "${COMPOSE[@]}" down --volumes > "$RUN_DIR/cleanup.log" 2>&1; then
      echo 'Test-container cleanup failed; see cleanup.log.' >&2
      status=1
    fi
  fi
  cd "$ROOT_DIR"
  rm -rf "$WORK_DIR"
  if [[ "$status" == 0 ]]; then printf 'PASS\n' > "$RUN_DIR/result.txt";
  else printf 'FAIL\n' > "$RUN_DIR/result.txt"; fi
  printf 'Exit status: %s\nCombined evidence: %s\n' "$status" "$RUN_DIR"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Copy just the inputs under test. Existing test files are deliberately excluded,
# so deleting the earlier per-task test packages cannot change this suite.
cd "$ROOT_DIR"
git rev-parse HEAD > "$RUN_DIR/base-commit.txt"
git branch --show-current > "$RUN_DIR/branch.txt"
"${HASH[@]}" scripts/test-persistence.sh database/Dockerfile database/changelog-master.yaml \
  database/changes/*.sql database/seed/10[123]-*.sql > "$RUN_DIR/source-inputs.sha256"
mkdir -p "$WORK_DIR/database/changes" "$WORK_DIR/database/seed" "$WORK_DIR/backend"
cp database/Dockerfile database/changelog-master.yaml "$WORK_DIR/database/"
cp database/changes/*.sql "$WORK_DIR/database/changes/"
cp database/seed/10[123]-*.sql "$WORK_DIR/database/seed/"
git ls-files --cached --others --exclude-standard -z -- src/backend |
  while IFS= read -r -d '' file; do
    case "$file" in
      *_test.go|*/testdata/*|src/backend/internal/events/contracts/*) continue ;;
      *.go|*/go.mod|*/go.sum|src/backend/api/openapi.yaml) ;;
      *) continue ;;
    esac
    [[ -f "$file" ]] || continue
    relative="${file#src/backend/}"
    mkdir -p "$WORK_DIR/backend/$(dirname "$relative")"
    cp "$file" "$WORK_DIR/backend/$relative"
    "${HASH[@]}" "$file" >> "$RUN_DIR/source-inputs.sha256"
  done

mysql_query() {
  local db="$1"; shift
  "${COMPOSE[@]}" exec -T -e MYSQL_PWD=persistence-test-only mysql mysql \
    --default-character-set=utf8mb4 --batch --raw -upersistence_test "$db" "$@"
}
lb() {
  local db="$1" label="$2"; shift 2
  "${COMPOSE[@]}" run --rm -T \
    -e "LIQUIBASE_COMMAND_CHANGELOG_FILE=$CHANGELOG" \
    -e "LIQUIBASE_COMMAND_URL=jdbc:mysql://mysql:3306/$db?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC" \
    liquibase "$@" > "$EVIDENCE_DIR/$db-$label.log" 2>&1 || {
      cat "$EVIDENCE_DIR/$db-$label.log" >&2; return 1;
    }
}
check_scalar() {
  local db="$1" name="$2" query="$3" expected="$4" actual
  actual="$(mysql_query "$db" --skip-column-names -e "$query")"
  printf '%s\t%s\t%s\n' "$name" "$actual" "$expected" >> "$EVIDENCE_DIR/migration-checks.tsv"
  [[ "$actual" == "$expected" ]] || { printf 'FAIL %s: %s != %s\n' "$name" "$actual" "$expected" >&2; return 1; }
}
dump_rows() {
  local db="$1" dest="$2"; shift 2
  "${COMPOSE[@]}" exec -T -e MYSQL_PWD=persistence-test-only mysql mysqldump -upersistence_test \
    --default-character-set=utf8mb4 --no-tablespaces --no-create-info --skip-extended-insert \
    --compact --skip-add-locks --skip-disable-keys --order-by-primary --skip-comments --skip-triggers \
    "$db" "$@" > "$dest"
}
run_go_tests() {
  local phase="$1" suite
  "${COMPOSE[@]}" run --rm -T go-tests go version > "$EVIDENCE_DIR/go-version.txt" 2>&1
  "${COMPOSE[@]}" run --rm -T \
    -e "C${phase}_INTEGRATION_DSN=persistence_test:persistence-test-only@tcp(mysql:3306)/c${phase}_clean?parseTime=true&loc=UTC&charset=utf8mb4&time_zone=%27%2B00%3A00%27" \
    go-tests go test -race -count=1 -v ./... > "$EVIDENCE_DIR/go-tests.txt" 2>&1 || {
      tail -100 "$EVIDENCE_DIR/go-tests.txt" >&2; return 1;
    }
  local required=(TestClaimPersistenceMySQL TestClaimUnknownCommitMySQL)
  if [[ "$phase" == 4 ]]; then required=(TestAssignmentPersistenceMySQL TestAssignmentUnknownCommitMySQL); fi
  for suite in "${required[@]}"; do
    if ! grep -q -- "--- PASS: $suite " "$EVIDENCE_DIR/go-tests.txt"; then
      printf 'Real-MySQL suite did not pass: %s\n' "$suite" >&2; return 1
    fi
  done
}

# The remainder of the test definitions is plain source in quoted heredocs.
# Runtime files exist only in WORK_DIR and are removed by the exit trap.
write_embedded_tests() {
  # Embedded compose.yaml
  cat > "$WORK_DIR/compose.yaml" <<'PERSISTENCE_EMBED_000'
services:
  mysql:
    image: mysql:8.4
    command: ["--max-connections=180"]
    environment:
      MYSQL_ROOT_PASSWORD: persistence-root-test-only
      MYSQL_USER: persistence_test
      MYSQL_PASSWORD: persistence-test-only
      MYSQL_DATABASE: c1_clean
      TZ: UTC
    volumes:
      - data:/var/lib/mysql
    healthcheck:
      test: [CMD-SHELL, 'MYSQL_PWD="$$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SELECT 1" >/dev/null 2>&1']
      interval: 2s
      timeout: 5s
      retries: 60
      start_period: 20s
  liquibase:
    build:
      context: ./database
      dockerfile: Dockerfile
    working_dir: /liquibase/changelog
    volumes:
      - ./database:/liquibase/changelog:ro
    environment:
      LIQUIBASE_COMMAND_USERNAME: persistence_test
      LIQUIBASE_COMMAND_PASSWORD: persistence-test-only
      LIQUIBASE_SEARCH_PATH: /liquibase/changelog
  go-tests:
    image: golang:1.26
    working_dir: /src
    volumes:
      - ./backend:/src
      - go-mod:/go/pkg/mod
      - go-build:/root/.cache/go-build
    environment:
      GOFLAGS: "-mod=readonly"
      C3_INTEGRATION_DSN: ""
      C4_INTEGRATION_DSN: ""
volumes:
  data:
  go-mod:
  go-build:
PERSISTENCE_EMBED_000

  # Embedded approved-migrations.sha256
  cat > "$WORK_DIR/approved-migrations.sha256" <<'PERSISTENCE_EMBED_001'
facea189139422d24a5350457f9382ea11e5a53b586f881d2e8adf06ef5fdf2d  database/changes/006-create-ewaste-batches.sql
750092fd220eae655e5bd71ca13e9114ab1b236832ad78e605d8485be42e2f6d  database/changes/007-add-ewaste-batch-constraints.sql
d9c717bd840d97817492c8512f327fdb36f56daa4de7e3180a52897719d317a7  database/changes/008-create-command-idempotency.sql
dde62efcb3d2fc97794a20fa26c9bb49235e577033f8d7945ebf144d9e9427fe  database/changes/009-create-batch-audit-events.sql
c5f7f67570d734cf22b63beffbb160c20e1d443bd7e6ab280a5f0107cb72aba5  database/changes/010-create-event-outbox.sql
cccc483ca42faacb11f9cfdf44146e81ce9790eb65d8479454647df7e73a3156  database/changes/011-create-matching-rule-sets.sql
285e36ceaaf0436a74e6179fc90545851c5f11e8920d37fda09f22f22deab6a9  database/changes/012-create-recycler-matching-profiles.sql
8c0eb85996401674aa53ebb933c2d83119236d9de234f600b6d3d88d08d1a88d  database/changes/013-create-recycler-capacity-pools.sql
b0631e3749707f889d7640a4d1e0965733fa62732fc304b92d4cb86f7f1d109e  database/changes/014-create-recycler-category-capabilities.sql
31c30af89685e532baabeca1154c0b4bfcfe639ccc8238045294063e93c5de33  database/changes/015-create-recycler-service-zones.sql
659685b17d5ff195b2c00021e4d23926789969c1442dd603de83707549e8b479  database/changes/016-create-matching-decisions.sql
63d835ada9140dfdeef36ecb11b0c15934b506c815bdfcb05ae00928cabf3004  database/changes/017-create-matched-results.sql
83856646edbfc5d6212d0b4346ae5b1c2216619c84d8ed5236c9ebd90e757d09  database/changes/018-create-batch-claims.sql
218011f9a6670f5a24a70014c45fc66e9f9074d9134c91b1f5a3147c41cdd44f  database/changes/019-create-capacity-reservations.sql
1651e5e61ebee8450f6cb6f5a9a940a46922b8f902cd350247a2e140c74a081a  database/changes/020-link-current-claim-and-audit.sql
7b61a1b5e62574d9dd98801efbc2802800d82d33a8349c192d22457f074d926a  database/changes/021-create-recycler-collector-scopes.sql
14ebedd497ecb4a6c6b49285e874dbbd96c46014fc02094fa33c250f89c9fff4  database/changes/022-create-batch-assignments.sql
b47e8efdfd0adb3dd4ead07d93ca500e9c67bd963bedbe27122b1090cf883920  database/changes/023-create-batch-handoffs.sql
ae9ff88f61bf6ecb78866b5bcf32ff0139baa37f06b856b8c6cdb7afc8780991  database/changes/024-create-assignment-actions.sql
d1850f775137ee9c0bc6ff82fcd8bc7f206b8ed98e4ef8a3dfa77618111c8ca2  database/changes/025-link-assignment-pointers-and-history.sql
PERSISTENCE_EMBED_001

  mkdir -p "$WORK_DIR/database/tests"
  # Embedded database/tests/verify-ew101-c1.sql
  cat > "$WORK_DIR/database/tests/verify-ew101-c1.sql" <<'PERSISTENCE_EMBED_002'
-- EW-101-C1 database verification queries.
-- The test runner treats any row whose result is FAIL as a failed test.

SELECT test_name, result, actual, expected
FROM (
    SELECT
        'schema.organisations_table' AS test_name,
        IF(COUNT(*) = 1, 'PASS', 'FAIL') AS result,
        CAST(COUNT(*) AS CHAR) AS actual,
        '1' AS expected
    FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = 'organisations'

    UNION ALL

    SELECT
        'schema.roles_table',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = 'roles'

    UNION ALL

    SELECT
        'schema.users_table',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = 'users'

    UNION ALL

    SELECT
        'schema.sessions_table',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = 'sessions'

    UNION ALL

    SELECT
        'schema.login_audit_table',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
        AND table_name = 'login_audit'

    UNION ALL

    SELECT
        'seed.organisation_count',
        IF(COUNT(*) = 7, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '7'
    FROM organisations

    UNION ALL

    SELECT
        'seed.role_count',
        IF(COUNT(*) = 5, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '5'
    FROM roles

    UNION ALL

    SELECT
        'seed.user_count',
        IF(COUNT(*) = 9, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '9'
    FROM users

    UNION ALL

    SELECT
        'seed.sessions_initially_empty',
        IF(COUNT(*) = 0, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '0'
    FROM sessions

    UNION ALL

    SELECT
        'seed.login_audit_initially_empty',
        IF(COUNT(*) = 0, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '0'
    FROM login_audit

    UNION ALL

    SELECT
        'integrity.no_orphan_users',
        IF(COUNT(*) = 0, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '0'
    FROM users u
    LEFT JOIN organisations o ON o.organisation_id = u.organisation_id
    LEFT JOIN roles r ON r.role_code = u.role_code
    WHERE o.organisation_id IS NULL OR r.role_code IS NULL

    UNION ALL

    SELECT
        'integrity.role_matches_organisation_type',
        IF(COUNT(*) = 0, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '0'
    FROM users u
    JOIN organisations o ON o.organisation_id = u.organisation_id
    JOIN roles r ON r.role_code = u.role_code
    WHERE o.organisation_type <> r.allowed_organisation_type

    UNION ALL

    SELECT
        'hierarchy.platform_admin_and_auditor',
        IF(COUNT(*) = 2, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '2'
    FROM users
    WHERE organisation_id = 'PLATFORM'
      AND role_code IN ('SYSTEM_ADMIN', 'AUDITOR')
      AND status = 'ACTIVE'

    UNION ALL

    SELECT
        'hierarchy.collection_operators',
        IF(COUNT(*) = 2, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '2'
    FROM users
    WHERE role_code = 'COLLECTOR'
      AND organisation_id IN ('COL-001', 'COL-002')
      AND status = 'ACTIVE'

    UNION ALL

    SELECT
        'hierarchy.recyclers',
        IF(COUNT(*) = 2, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '2'
    FROM users
    WHERE role_code = 'RECYCLER'
      AND organisation_id IN ('PROC-001', 'PROC-002')
      AND status = 'ACTIVE'

    UNION ALL

    SELECT
        'negative.disabled_user',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM users
    WHERE email = 'disabled@ewaste.test'
      AND status = 'DISABLED'

    UNION ALL

    SELECT
        'security.passwords_are_bcrypt_hashes',
        IF(COUNT(*) = 9, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '9'
    FROM users
    WHERE CHAR_LENGTH(password_hash) = 60
      AND LEFT(password_hash, 4) IN ('$2a$', '$2b$', '$2y$')

    UNION ALL

    SELECT
        'security.no_plaintext_seed_password',
        IF(COUNT(*) = 0, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '0'
    FROM users
    WHERE password_hash = 'TestOnly#2026!'

    UNION ALL

    SELECT
        'security.token_hash_column_present',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'sessions'
      AND column_name = 'token_hash'
      AND data_type = 'char'
      AND character_maximum_length = 64
      AND is_nullable = 'NO'

    UNION ALL

    SELECT
        'security.no_raw_token_storage',
        IF(COUNT(*) = 0, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '0'
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
      AND table_name = 'sessions'
      AND column_name IN (
          'token',
          'jwt',
          'jwt_token',
          'access_token',
          'refresh_token',
          'access_jwt',
          'refresh_jwt'
      )

    UNION ALL

    SELECT
        'constraint.unique_session_token_hash',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.statistics
    WHERE table_schema = DATABASE()
      AND table_name = 'sessions'
      AND index_name = 'uq_sessions_token_hash'
      AND non_unique = 0

    UNION ALL

    SELECT
        'constraint.unique_user_email',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.statistics
    WHERE table_schema = DATABASE()
      AND table_name = 'users'
      AND index_name = 'uq_users_email'
      AND non_unique = 0

    UNION ALL

    SELECT
        'constraint.expected_foreign_keys',
        IF(COUNT(*) = 4, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '4'
    FROM information_schema.referential_constraints
    WHERE constraint_schema = DATABASE()
      AND constraint_name IN (
          'fk_users_role',
          'fk_users_organisation',
          'fk_sessions_user',
          'fk_login_audit_user'
      )

    UNION ALL

    SELECT
        'session.primary_key_supports_jwt_jti',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
        AND table_name = 'sessions'
        AND column_name = 'session_id'
        AND character_maximum_length = 36

    UNION ALL

    SELECT
        'audit.correlation_id_present',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.columns
    WHERE table_schema = DATABASE()
        AND table_name = 'login_audit'
        AND column_name = 'correlation_id'
) checks
ORDER BY test_name;
PERSISTENCE_EMBED_002

  mkdir -p "$WORK_DIR/database/tests/c1"
  # Embedded database/tests/c1/changelog-sprint1.yaml
  cat > "$WORK_DIR/database/tests/c1/changelog-sprint1.yaml" <<'PERSISTENCE_EMBED_003'
# Exact pre-C1 include paths preserve existing DATABASECHANGELOG identities.
databaseChangeLog:
  - include:
      file: changes/001-create-organisations.sql
  - include:
      file: changes/002-create-roles.sql
  - include:
      file: changes/003-create-users.sql
  - include:
      file: changes/004-create-sessions.sql
  - include:
      file: changes/005-create-login-audit.sql
  - include:
      file: seed/101-seed-organisations.sql
  - include:
      file: seed/102-seed-roles.sql
  - include:
      file: seed/103-seed-users.sql
PERSISTENCE_EMBED_003

  mkdir -p "$WORK_DIR/database/tests/c1"
  # Embedded database/tests/c1/changelog-c1.yaml
  cat > "$WORK_DIR/database/tests/c1/changelog-c1.yaml" <<'PERSISTENCE_EMBED_004'
# Frozen C1 test boundary; includes preserve the original Liquibase file identities.
databaseChangeLog:
  - include:
      file: changes/001-create-organisations.sql
  - include:
      file: changes/002-create-roles.sql
  - include:
      file: changes/003-create-users.sql
  - include:
      file: changes/004-create-sessions.sql
  - include:
      file: changes/005-create-login-audit.sql
  - include:
      file: changes/006-create-ewaste-batches.sql
  - include:
      file: changes/007-add-ewaste-batch-constraints.sql
  - include:
      file: changes/008-create-command-idempotency.sql
  - include:
      file: changes/009-create-batch-audit-events.sql
  - include:
      file: changes/010-create-event-outbox.sql
  - include:
      file: seed/101-seed-organisations.sql
  - include:
      file: seed/102-seed-roles.sql
  - include:
      file: seed/103-seed-users.sql
  - include:
      file: seed/104-seed-c1-batches.sql
PERSISTENCE_EMBED_004

  mkdir -p "$WORK_DIR/database/tests/c1"
  # Embedded database/tests/c1/verify.sql
  cat > "$WORK_DIR/database/tests/c1/verify.sql" <<'PERSISTENCE_EMBED_005'
-- EWCSB-126 runtime checks. Run only in the runner's disposable MySQL database.
-- Fixture mutations are rolled back. The transaction test commits one extra batch.
-- Expected errors include the exact MySQL error number and named constraint.
SET NAMES utf8mb4;
SET time_zone = '+00:00';
SET SESSION group_concat_max_len = 16384;
CREATE TEMPORARY TABLE c1_results (
    sequence_id INT AUTO_INCREMENT PRIMARY KEY,
    test_name VARCHAR(128) NOT NULL UNIQUE,
    result VARCHAR(4) NOT NULL,
    actual VARCHAR(4096),
    expected VARCHAR(4096)
) ENGINE=MEMORY;
DELIMITER $$
CREATE PROCEDURE c1_assert(IN p_name VARCHAR(128), IN p_actual TEXT, IN p_expected TEXT)
BEGIN
    INSERT INTO c1_results(test_name, result, actual, expected)
    VALUES(p_name, IF(BINARY p_actual <=> BINARY p_expected, 'PASS', 'FAIL'), p_actual, p_expected);
END$$
CREATE PROCEDURE c1_statement(
    IN p_name VARCHAR(128), IN p_sql LONGTEXT,
    IN p_errno INT, IN p_constraint VARCHAR(128))
BEGIN
    DECLARE observed INT DEFAULT 0;
    DECLARE message_text_value TEXT DEFAULT '';
    DECLARE affected INT DEFAULT 0;
    DECLARE prepared_ok BOOLEAN DEFAULT FALSE;
    START TRANSACTION;
    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
            GET DIAGNOSTICS CONDITION 1 observed = MYSQL_ERRNO, message_text_value = MESSAGE_TEXT;
        SET @c1_statement = p_sql;
        PREPARE c1_prepared FROM @c1_statement;
        SET prepared_ok = TRUE;
        EXECUTE c1_prepared;
        SET affected = ROW_COUNT();
    END;
    IF prepared_ok THEN DEALLOCATE PREPARE c1_prepared; END IF;
    ROLLBACK;
    INSERT INTO c1_results(test_name, result, actual, expected)
    VALUES(p_name,
        IF(observed = p_errno
           AND (p_errno <> 0 OR affected = 1)
           AND (p_constraint = '' OR LOCATE(p_constraint, message_text_value) > 0), 'PASS', 'FAIL'),
        IF(observed = 0, CONCAT('accepted rows=', affected), CONCAT(observed, ': ', message_text_value)),
        IF(p_errno = 0, 'accepted rows=1', CONCAT(p_errno, ': ', p_constraint)));
END$$
CREATE PROCEDURE c1_clone(
    IN p_name VARCHAR(128), IN p_table VARCHAR(64), IN p_source VARCHAR(36),
    IN p_id VARCHAR(36), IN p_patch JSON, IN p_errno INT, IN p_constraint VARCHAR(128))
BEGIN
    DECLARE columns_sql TEXT;
    DECLARE values_sql TEXT;
    DECLARE pk_name VARCHAR(16);
    IF p_table NOT IN ('ewaste_batches','command_idempotency','batch_audit_events','event_outbox') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid test table';
    END IF;
    SET pk_name = IF(p_table = 'event_outbox', 'event_id', 'id');
    SELECT GROUP_CONCAT(CONCAT('`', COLUMN_NAME, '`') ORDER BY ORDINAL_POSITION),
           GROUP_CONCAT(CASE
               WHEN JSON_CONTAINS_PATH(p_patch, 'one', CONCAT('$.', COLUMN_NAME))
                   THEN JSON_UNQUOTE(JSON_EXTRACT(p_patch, CONCAT('$.', COLUMN_NAME)))
               WHEN COLUMN_NAME = pk_name THEN QUOTE(p_id)
               ELSE CONCAT('b.`', COLUMN_NAME, '`') END ORDER BY ORDINAL_POSITION)
    INTO columns_sql, values_sql
    FROM information_schema.columns WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table;
    CALL c1_statement(p_name,
        CONCAT('INSERT INTO ', p_table, ' (', columns_sql, ') SELECT ', values_sql,
               ' FROM ', p_table, ' b WHERE b.', pk_name, ' = ', QUOTE(p_source)),
        p_errno, p_constraint);
END$$
CREATE PROCEDURE c1_finish()
BEGIN
    IF EXISTS(SELECT 1 FROM c1_results WHERE result <> 'PASS') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'EWCSB-126 persistence check failed';
    END IF;
END$$
DELIMITER ;

CALL c1_assert('runtime.mysql_8_4', CAST((VERSION() LIKE '8.4.%') AS CHAR), '1');

CALL c1_assert('runtime.strict_mode', CAST((FIND_IN_SET('STRICT_TRANS_TABLES', @@sql_mode) > 0 OR FIND_IN_SET('STRICT_ALL_TABLES', @@sql_mode) > 0) AS CHAR), '1');

CALL c1_assert('runtime.utc', CAST((@@session.time_zone) AS CHAR), '+00:00');

CALL c1_assert('schema.ewaste_batches_columns', CAST((SELECT COUNT(*) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches') AS CHAR), '19');

CALL c1_assert('schema.ewaste_batches_engine', CAST((SELECT CONCAT(ENGINE, '/', TABLE_COLLATION) FROM information_schema.tables WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches') AS CHAR), 'InnoDB/utf8mb4_0900_ai_ci');

CALL c1_assert('schema.command_idempotency_columns', CAST((SELECT COUNT(*) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='command_idempotency') AS CHAR), '15');

CALL c1_assert('schema.command_idempotency_engine', CAST((SELECT CONCAT(ENGINE, '/', TABLE_COLLATION) FROM information_schema.tables WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='command_idempotency') AS CHAR), 'InnoDB/utf8mb4_0900_ai_ci');

CALL c1_assert('schema.batch_audit_events_columns', CAST((SELECT COUNT(*) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='batch_audit_events') AS CHAR), '16');

CALL c1_assert('schema.batch_audit_events_engine', CAST((SELECT CONCAT(ENGINE, '/', TABLE_COLLATION) FROM information_schema.tables WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='batch_audit_events') AS CHAR), 'InnoDB/utf8mb4_0900_ai_ci');

CALL c1_assert('schema.event_outbox_columns', CAST((SELECT COUNT(*) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='event_outbox') AS CHAR), '18');

CALL c1_assert('schema.event_outbox_engine', CAST((SELECT CONCAT(ENGINE, '/', TABLE_COLLATION) FROM information_schema.tables WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='event_outbox') AS CHAR), 'InnoDB/utf8mb4_0900_ai_ci');

CALL c1_assert('schema.batch.id', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='id') AS CHAR), 'varchar(36)/NO');

CALL c1_assert('schema.batch.organization_id', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='organization_id') AS CHAR), 'varchar(32)/NO');

CALL c1_assert('schema.batch.created_by', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='created_by') AS CHAR), 'varchar(32)/NO');

CALL c1_assert('schema.batch.status', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='status') AS CHAR), 'varchar(32)/NO');

CALL c1_assert('schema.batch.category', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='category') AS CHAR), 'varchar(32)/YES');

CALL c1_assert('schema.batch.quantity', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='quantity') AS CHAR), 'int unsigned/YES');

CALL c1_assert('schema.batch.estimated_weight_kg', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='estimated_weight_kg') AS CHAR), 'decimal(8,2)/YES');

CALL c1_assert('schema.batch.condition_rating', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='condition_rating') AS CHAR), 'varchar(32)/YES');

CALL c1_assert('schema.batch.is_data_bearing', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='is_data_bearing') AS CHAR), 'tinyint(1)/NO');

CALL c1_assert('schema.batch.zone', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='zone') AS CHAR), 'varchar(16)/YES');

CALL c1_assert('schema.batch.collection_deadline', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='collection_deadline') AS CHAR), 'datetime(6)/YES');

CALL c1_assert('schema.batch.notes', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='notes') AS CHAR), 'varchar(500)/YES');

CALL c1_assert('schema.batch.claim_epoch', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='claim_epoch') AS CHAR), 'bigint unsigned/NO');

CALL c1_assert('schema.batch.current_claim_id', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='current_claim_id') AS CHAR), 'varchar(36)/YES');

CALL c1_assert('schema.batch.current_assignment_id', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='current_assignment_id') AS CHAR), 'varchar(36)/YES');

CALL c1_assert('schema.batch.version', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='version') AS CHAR), 'int unsigned/NO');

CALL c1_assert('schema.batch.submitted_at', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='submitted_at') AS CHAR), 'datetime(6)/YES');

CALL c1_assert('schema.batch.created_at', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='created_at') AS CHAR), 'datetime(6)/NO');

CALL c1_assert('schema.batch.updated_at', CAST((SELECT CONCAT(COLUMN_TYPE, '/', IS_NULLABLE) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME='updated_at') AS CHAR), 'datetime(6)/NO');

CALL c1_assert('schema.case_sensitive_codes', CAST((SELECT COUNT(*) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND COLUMN_NAME IN ('status','category','condition_rating','zone') AND COLLATION_NAME='utf8mb4_0900_as_cs') AS CHAR), '4');

CALL c1_assert('schema.identity_fk_collations', CAST((SELECT COUNT(*) FROM information_schema.columns child JOIN information_schema.columns parent ON parent.TABLE_SCHEMA=child.TABLE_SCHEMA AND ((child.COLUMN_NAME='organization_id' AND parent.TABLE_NAME='organisations' AND parent.COLUMN_NAME='organisation_id') OR (child.COLUMN_NAME='created_by' AND parent.TABLE_NAME='users' AND parent.COLUMN_NAME='user_id')) WHERE child.TABLE_SCHEMA=DATABASE() AND child.TABLE_NAME='ewaste_batches' AND child.COLUMN_TYPE=parent.COLUMN_TYPE AND child.COLLATION_NAME=parent.COLLATION_NAME) AS CHAR), '2');

CALL c1_assert('schema.replay_key_case_sensitive', CAST((SELECT COUNT(*) FROM information_schema.columns WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='command_idempotency' AND COLUMN_NAME IN ('actor_scope','command_name','idempotency_key') AND COLLATION_NAME='utf8mb4_0900_as_cs') AS CHAR), '3');

CALL c1_assert('schema.ewaste_batches_enforced_checks', CAST((SELECT GROUP_CONCAT(CONSTRAINT_NAME ORDER BY CONSTRAINT_NAME) FROM information_schema.table_constraints WHERE CONSTRAINT_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND CONSTRAINT_TYPE='CHECK' AND ENFORCED='YES') AS CHAR), 'ck_batches_c1_assignment_null,ck_batches_c1_claim_null,ck_batches_category,ck_batches_condition,ck_batches_data_bearing,ck_batches_epoch,ck_batches_quantity,ck_batches_status,ck_batches_submit_completeness,ck_batches_submitted_time,ck_batches_updated_time,ck_batches_version,ck_batches_weight,ck_batches_zone');

CALL c1_assert('schema.command_idempotency_enforced_checks', CAST((SELECT GROUP_CONCAT(CONSTRAINT_NAME ORDER BY CONSTRAINT_NAME) FROM information_schema.table_constraints WHERE CONSTRAINT_SCHEMA=DATABASE() AND TABLE_NAME='command_idempotency' AND CONSTRAINT_TYPE='CHECK' AND ENFORCED='YES') AS CHAR), 'ck_command_actor_mode,ck_command_c1_assignment_null,ck_command_completion,ck_command_retention,ck_command_state');

CALL c1_assert('schema.batch_audit_events_enforced_checks', CAST((SELECT GROUP_CONCAT(CONSTRAINT_NAME ORDER BY CONSTRAINT_NAME) FROM information_schema.table_constraints WHERE CONSTRAINT_SCHEMA=DATABASE() AND TABLE_NAME='batch_audit_events' AND CONSTRAINT_TYPE='CHECK' AND ENFORCED='YES') AS CHAR), 'ck_batch_audit_actor_mode,ck_batch_audit_c1_assignment_null,ck_batch_audit_c1_claim_null,ck_batch_audit_from_state,ck_batch_audit_sequence,ck_batch_audit_to_state,ck_batch_audit_version');

CALL c1_assert('schema.event_outbox_enforced_checks', CAST((SELECT GROUP_CONCAT(CONSTRAINT_NAME ORDER BY CONSTRAINT_NAME) FROM information_schema.table_constraints WHERE CONSTRAINT_SCHEMA=DATABASE() AND TABLE_NAME='event_outbox' AND CONSTRAINT_TYPE='CHECK' AND ENFORCED='YES') AS CHAR), 'ck_outbox_aggregate_version,ck_outbox_attempts,ck_outbox_delivery_metadata,ck_outbox_key,ck_outbox_schema_version,ck_outbox_sequence,ck_outbox_state');

CALL c1_assert('index.idx_batches_org_status', CAST((SELECT CONCAT(MIN(NON_UNIQUE), ':', GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)) FROM information_schema.statistics WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND INDEX_NAME='idx_batches_org_status') AS CHAR), '1:organization_id,status,created_at,id');

CALL c1_assert('index.idx_batches_org_created', CAST((SELECT CONCAT(MIN(NON_UNIQUE), ':', GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)) FROM information_schema.statistics WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND INDEX_NAME='idx_batches_org_created') AS CHAR), '1:organization_id,created_at,id');

CALL c1_assert('index.idx_batches_creator', CAST((SELECT CONCAT(MIN(NON_UNIQUE), ':', GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)) FROM information_schema.statistics WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ewaste_batches' AND INDEX_NAME='idx_batches_creator') AS CHAR), '1:created_by');

CALL c1_assert('index.uq_command_replay', CAST((SELECT CONCAT(MIN(NON_UNIQUE), ':', GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)) FROM information_schema.statistics WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='command_idempotency' AND INDEX_NAME='uq_command_replay') AS CHAR), '0:actor_scope,command_name,idempotency_key');

CALL c1_assert('index.uq_batch_audit_command_seq', CAST((SELECT CONCAT(MIN(NON_UNIQUE), ':', GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)) FROM information_schema.statistics WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='batch_audit_events' AND INDEX_NAME='uq_batch_audit_command_seq') AS CHAR), '0:command_id,sequence_in_command');

CALL c1_assert('index.uq_outbox_command_event', CAST((SELECT CONCAT(MIN(NON_UNIQUE), ':', GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)) FROM information_schema.statistics WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='event_outbox' AND INDEX_NAME='uq_outbox_command_event') AS CHAR), '0:command_id,batch_id,event_type');

CALL c1_assert('index.uq_outbox_command_seq', CAST((SELECT CONCAT(MIN(NON_UNIQUE), ':', GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)) FROM information_schema.statistics WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='event_outbox' AND INDEX_NAME='uq_outbox_command_seq') AS CHAR), '0:command_id,sequence_in_command');

CALL c1_assert('schema.restrictive_foreign_keys', CAST((SELECT COUNT(*) FROM information_schema.referential_constraints WHERE CONSTRAINT_SCHEMA=DATABASE() AND TABLE_NAME IN ('ewaste_batches','command_idempotency','batch_audit_events','event_outbox') AND DELETE_RULE IN ('RESTRICT','NO ACTION') AND UPDATE_RULE IN ('RESTRICT','NO ACTION')) AS CHAR), '10');

CALL c1_assert('schema.no_later_slice_tables', CAST((SELECT COUNT(*) FROM information_schema.tables WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ('batch_claims','capacity_reservations','batch_assignments','batch_handoffs','matching_decisions')) AS CHAR), '0');

-- Persisted fixtures and complete command/audit/outbox relationships.

CALL c1_assert('fixture.ewaste_batches_count', CAST((SELECT COUNT(*) FROM ewaste_batches) AS CHAR), '7');

CALL c1_assert('fixture.command_idempotency_count', CAST((SELECT COUNT(*) FROM command_idempotency) AS CHAR), '12');

CALL c1_assert('fixture.batch_audit_events_count', CAST((SELECT COUNT(*) FROM batch_audit_events) AS CHAR), '12');

CALL c1_assert('fixture.event_outbox_count', CAST((SELECT COUNT(*) FROM event_outbox) AS CHAR), '5');

CALL c1_assert('fixture.minimal_draft', CAST((SELECT COUNT(*) FROM ewaste_batches WHERE id='b1260000-0000-4000-8000-000000000001' AND status='DRAFT' AND version=1 AND claim_epoch=1 AND submitted_at IS NULL AND category IS NULL AND quantity IS NULL AND estimated_weight_kg IS NULL AND condition_rating IS NULL AND zone IS NULL AND collection_deadline IS NULL AND notes IS NULL AND is_data_bearing=0) AS CHAR), '1');

CALL c1_assert('fixture.partial_draft', CAST((SELECT COUNT(*) FROM ewaste_batches WHERE id='b1260000-0000-4000-8000-000000000002' AND status='DRAFT' AND category='BATTERIES' AND quantity=1 AND estimated_weight_kg IS NULL AND condition_rating IS NULL AND zone='WEST' AND is_data_bearing=1 AND submitted_at IS NULL) AS CHAR), '1');

CALL c1_assert('fixture.minimum_boundaries', CAST((SELECT COUNT(*) FROM ewaste_batches WHERE quantity=1 AND estimated_weight_kg=0.10 AND collection_deadline=submitted_at+INTERVAL 48 HOUR AND status='SUBMITTED') AS CHAR), '1');

CALL c1_assert('fixture.maximum_boundaries', CAST((SELECT COUNT(*) FROM ewaste_batches WHERE quantity=100000 AND estimated_weight_kg=50000.00 AND collection_deadline=submitted_at+INTERVAL 90 DAY AND CHAR_LENGTH(notes)=500 AND OCTET_LENGTH(notes)=1500) AS CHAR), '1');

CALL c1_assert('fixture.all_categories', CAST((SELECT COUNT(DISTINCT category) FROM ewaste_batches WHERE status='SUBMITTED') AS CHAR), '4');

CALL c1_assert('fixture.all_conditions', CAST((SELECT COUNT(DISTINCT condition_rating) FROM ewaste_batches WHERE status='SUBMITTED') AS CHAR), '3');

CALL c1_assert('fixture.all_zones', CAST((SELECT COUNT(DISTINCT zone) FROM ewaste_batches WHERE status='SUBMITTED') AS CHAR), '5');

CALL c1_assert('fixture.all_booleans', CAST((SELECT COUNT(DISTINCT is_data_bearing) FROM ewaste_batches WHERE status='SUBMITTED') AS CHAR), '2');

CALL c1_assert('fixture.exact_decimal_roundtrip', CAST((SELECT CAST(estimated_weight_kg AS CHAR) FROM ewaste_batches WHERE id='b1260000-0000-4000-8000-000000000005') AS CHAR), '12.34');

CALL c1_assert('fixture.null_claim_assignment', CAST((SELECT COUNT(*) FROM ewaste_batches WHERE current_claim_id IS NULL AND current_assignment_id IS NULL AND claim_epoch=1) AS CHAR), '7');

CALL c1_assert('fixture.donor_membership', CAST((SELECT COUNT(*) FROM ewaste_batches b JOIN users u ON u.user_id=b.created_by AND u.organisation_id=b.organization_id WHERE u.role_code='DONOR' AND u.status='ACTIVE') AS CHAR), '7');

CALL c1_assert('fixture.submission_atomic_links', CAST((SELECT COUNT(*) FROM ewaste_batches b JOIN command_idempotency c ON c.batch_id=b.id AND c.command_name='SubmitBatch' JOIN batch_audit_events a ON a.command_id=c.id AND a.batch_id=b.id AND a.actor_user_id=b.created_by AND a.actor_org_id=b.organization_id JOIN event_outbox e ON e.command_id=c.id AND e.batch_id=b.id WHERE b.status='SUBMITTED' AND b.version=2 AND c.state='COMPLETED' AND c.response_status=200 AND JSON_UNQUOTE(JSON_EXTRACT(c.response_json,'$.eventId'))=e.event_id AND a.event_type='RequestSubmitted' AND a.from_status='DRAFT' AND a.to_status='SUBMITTED' AND a.batch_version=b.version AND e.aggregate_version=b.version AND e.publish_state='PENDING' AND e.occurred_at=b.submitted_at AND e.correlation_id=a.correlation_id) AS CHAR), '5');

CALL c1_assert('fixture.draft_history', CAST((SELECT COUNT(*) FROM batch_audit_events WHERE event_type='DraftSaved' AND from_status='DRAFT' AND to_status='DRAFT' AND batch_version=1 AND JSON_UNQUOTE(JSON_EXTRACT(details_json,'$.operation'))='CREATE') AS CHAR), '7');

CALL c1_assert('fixture.no_draft_kafka_event', CAST((SELECT COUNT(*) FROM event_outbox e JOIN ewaste_batches b ON b.id=e.batch_id WHERE b.status='DRAFT') AS CHAR), '0');

CALL c1_assert('fixture.event_envelope_and_payload_types', CAST((SELECT COUNT(*) FROM event_outbox e WHERE JSON_LENGTH(payload_json)=11 AND JSON_LENGTH(JSON_EXTRACT(payload_json,'$.data'))=9 AND JSON_TYPE(JSON_EXTRACT(payload_json,'$.claim_epoch'))='STRING' AND JSON_TYPE(JSON_EXTRACT(payload_json,'$.batch_version')) IN ('INTEGER','UNSIGNED INTEGER') AND JSON_TYPE(JSON_EXTRACT(payload_json,'$.data.quantity')) IN ('INTEGER','UNSIGNED INTEGER') AND JSON_TYPE(JSON_EXTRACT(payload_json,'$.data.estimated_weight_kg'))='STRING' AND JSON_TYPE(JSON_EXTRACT(payload_json,'$.data.is_data_bearing'))='BOOLEAN' AND JSON_UNQUOTE(JSON_EXTRACT(payload_json,'$.event_id'))=event_id AND JSON_UNQUOTE(JSON_EXTRACT(payload_json,'$.command_id'))=command_id AND JSON_UNQUOTE(JSON_EXTRACT(payload_json,'$.batch_id'))=batch_id AND partition_key=batch_id AND JSON_EXTRACT(payload_json,'$.data.notes') IS NULL AND JSON_EXTRACT(payload_json,'$.data.actor_user_id') IS NULL) AS CHAR), '5');

-- Each invalid INSERT must fail for the expected constraint, not another error.

CALL c1_clone('reject.batch.unknown_status', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('status', '''NO_MATCH'''), 3819, 'ck_batches_status');

CALL c1_clone('reject.batch.status_case', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('status', '''submitted'''), 3819, 'ck_batches_status');

CALL c1_clone('reject.batch.unknown_category', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('category', '''UNKNOWN'''), 3819, 'ck_batches_category');

CALL c1_clone('reject.batch.category_case', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('category', '''ict_equipment'''), 3819, 'ck_batches_category');

CALL c1_clone('reject.batch.quantity_zero', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('quantity', '0'), 3819, 'ck_batches_quantity');

CALL c1_clone('reject.batch.quantity_above_max', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('quantity', '100001'), 3819, 'ck_batches_quantity');

CALL c1_clone('reject.batch.quantity_negative', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('quantity', '-1'), 1264, 'quantity');

CALL c1_clone('reject.batch.weight_below_min', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('estimated_weight_kg', '0.09'), 3819, 'ck_batches_weight');

CALL c1_clone('reject.batch.weight_above_max', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('estimated_weight_kg', '50000.01'), 3819, 'ck_batches_weight');

CALL c1_clone('reject.batch.unknown_condition', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('condition_rating', '''BROKEN'''), 3819, 'ck_batches_condition');

CALL c1_clone('reject.batch.condition_case', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('condition_rating', '''functional'''), 3819, 'ck_batches_condition');

CALL c1_clone('reject.batch.non_boolean', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('is_data_bearing', '2'), 3819, 'ck_batches_data_bearing');

CALL c1_clone('reject.batch.null_boolean', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('is_data_bearing', 'NULL'), 1048, 'is_data_bearing');

CALL c1_clone('reject.batch.unknown_zone', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('zone', '''REMOTE'''), 3819, 'ck_batches_zone');

CALL c1_clone('reject.batch.zone_case', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('zone', '''north'''), 3819, 'ck_batches_zone');

CALL c1_clone('reject.batch.deadline_1us_early', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('collection_deadline', '''2026-09-03 00:59:59.999999'''), 3819, 'ck_batches_submit_completeness');

CALL c1_clone('reject.batch.deadline_1us_late', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('collection_deadline', '''2026-11-30 01:00:00.000001'''), 3819, 'ck_batches_submit_completeness');

CALL c1_clone('reject.batch.notes_501_characters', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('notes', 'REPEAT(''界'',501)'), 1406, 'notes');

CALL c1_clone('reject.batch.epoch_zero', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('claim_epoch', '0'), 3819, 'ck_batches_epoch');

CALL c1_clone('reject.batch.version_zero', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('version', '0'), 3819, 'ck_batches_version');

CALL c1_clone('reject.batch.updated_before_created', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('updated_at', '''2026-08-31 23:59:59.999999'''), 3819, 'ck_batches_updated_time');

CALL c1_clone('reject.batch.submitted_before_created', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('submitted_at', '''2026-08-31 23:59:59.999999'''), 3819, 'ck_batches_submitted_time');

CALL c1_clone('reject.batch.claim_pointer', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('current_claim_id', '''c1269999-0000-4000-8000-000000000001'''), 3819, 'ck_batches_c1_claim_null');

CALL c1_clone('reject.batch.assignment_pointer', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('current_assignment_id', '''a1269999-0000-4000-8000-000000000001'''), 3819, 'ck_batches_c1_assignment_null');

CALL c1_clone('reject.batch.missing_organisation', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('organization_id', '''NONEXISTENT'''), 1452, 'fk_batches_organisation');

CALL c1_clone('reject.batch.missing_creator', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('created_by', '''NONEXISTENT'''), 1452, 'fk_batches_creator');

CALL c1_clone('reject.batch.null_organisation', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('organization_id', 'NULL'), 1048, 'organization_id');

CALL c1_clone('reject.batch.null_creator', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('created_by', 'NULL'), 1048, 'created_by');

CALL c1_clone('reject.batch.missing_category', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('category', 'NULL'), 3819, 'ck_batches_submit_completeness');

CALL c1_clone('reject.batch.missing_quantity', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('quantity', 'NULL'), 3819, 'ck_batches_submit_completeness');

CALL c1_clone('reject.batch.missing_estimated_weight_kg', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('estimated_weight_kg', 'NULL'), 3819, 'ck_batches_submit_completeness');

CALL c1_clone('reject.batch.missing_condition_rating', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('condition_rating', 'NULL'), 3819, 'ck_batches_submit_completeness');

CALL c1_clone('reject.batch.missing_zone', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('zone', 'NULL'), 3819, 'ck_batches_submit_completeness');

CALL c1_clone('reject.batch.missing_collection_deadline', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('collection_deadline', 'NULL'), 3819, 'ck_batches_submit_completeness');

CALL c1_clone('reject.batch.missing_submitted_at', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('submitted_at', 'NULL'), 3819, 'ck_batches_submit_completeness');

CALL c1_clone('reject.batch.draft_has_submission_time', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('status', '''DRAFT'''), 3819, 'ck_batches_submit_completeness');

CALL c1_clone('reject.batch.invalid_partial_draft', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000002', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('quantity', '0'), 3819, 'ck_batches_quantity');

CALL c1_clone('reject.batch.duplicate_id', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1260000-0000-4000-8000-000000000003',
    JSON_OBJECT(), 1062, 'PRIMARY');

CALL c1_clone('valid.batch.submitted', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT(), 0, '');

CALL c1_clone('valid.batch.partial_draft', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000002', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT(), 0, '');

CALL c1_clone('valid.batch.full_u64_epoch', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('claim_epoch', '18446744073709551615'), 0, '');

CALL c1_clone('valid.batch.full_u32_version', 'ewaste_batches', 'b1260000-0000-4000-8000-000000000003', 'b1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('version', '4294967295'), 0, '');

-- Command state, scope, case sensitivity and referential constraints.

CALL c1_clone('valid.command.valid_same_key_different_actor', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('actor_scope', '''user:USR-004''', 'actor_user_id', '''USR-004'''), 0, '');

CALL c1_clone('valid.command.valid_same_key_different_command', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_name', '''CreateDraft'''), 0, '');

CALL c1_clone('valid.command.valid_key_case_distinct', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', 'UPPER(b.idempotency_key)'), 0, '');

CALL c1_clone('reject.command.duplicate_scope_key', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT(), 1062, 'uq_command_replay');

CALL c1_clone('reject.command.missing_actor', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', '''c1-test-new-key''', 'actor_user_id', 'NULL'), 3819, 'ck_command_actor_mode');

CALL c1_clone('reject.command.two_actor_modes', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', '''c1-test-new-key''', 'service_principal', '''service:test'''), 3819, 'ck_command_actor_mode');

-- Unknown state violates both the state enum and completion-shape checks.
CALL c1_clone('reject.command.invalid_state', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', '''c1-test-new-key''', 'state', '''PREPARED'''), 3819, 'ck_command_completion');

CALL c1_clone('reject.command.completed_without_response', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', '''c1-test-new-key''', 'response_json', 'NULL'), 3819, 'ck_command_completion');

CALL c1_clone('reject.command.completed_without_status', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', '''c1-test-new-key''', 'response_status', 'NULL'), 3819, 'ck_command_completion');

CALL c1_clone('reject.command.completed_without_time', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', '''c1-test-new-key''', 'completed_at', 'NULL'), 3819, 'ck_command_completion');

CALL c1_clone('reject.command.completed_before_created', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', '''c1-test-new-key''', 'completed_at', '''2026-09-01 00:59:59.999999'''), 3819, 'ck_command_completion');

CALL c1_clone('reject.command.retention_before_completion', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', '''c1-test-new-key''', 'retain_until', '''2026-09-01 00:00:00.000000'''), 3819, 'ck_command_completion');

CALL c1_clone('reject.command.assignment_pointer', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', '''c1-test-new-key''', 'assignment_id', '''a1269999-0000-4000-8000-000000000001'''), 3819, 'ck_command_c1_assignment_null');

CALL c1_clone('reject.command.missing_user_fk', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', '''c1-test-new-key''', 'actor_user_id', '''UNKNOWN'''), 1452, 'fk_command_actor');

CALL c1_clone('reject.command.missing_batch_fk', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', '''c1-test-new-key''', 'batch_id', '''b1269999-0000-4000-8000-000000000001'''), 1452, 'fk_command_batch');

CALL c1_clone('valid.command.valid_in_progress', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', '''c1-test-new-key''', 'state', '''IN_PROGRESS''', 'response_status', 'NULL', 'response_json', 'JSON_OBJECT(''prepared'',true)', 'completed_at', 'NULL'), 0, '');

CALL c1_clone('valid.command.valid_service_actor', 'command_idempotency', 'c1260001-0000-4000-8000-000000000003', 'c1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('idempotency_key', '''c1-test-new-key''', 'actor_user_id', 'NULL', 'service_principal', '''test:fixture-worker''', 'actor_scope', '''service:fixture-worker'''), 0, '');

CALL c1_clone('reject.audit.duplicate_command_sequence', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT(), 1062, 'uq_batch_audit_command_seq');

CALL c1_clone('valid.audit.valid_human', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2'), 0, '');

CALL c1_clone('valid.audit.valid_service', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2', 'actor_user_id', 'NULL', 'actor_org_id', 'NULL', 'service_principal', '''test:fixture-worker'''), 0, '');

CALL c1_clone('reject.audit.missing_org', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2', 'actor_org_id', 'NULL'), 3819, 'ck_batch_audit_actor_mode');

CALL c1_clone('reject.audit.missing_user', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2', 'actor_user_id', 'NULL'), 3819, 'ck_batch_audit_actor_mode');

CALL c1_clone('reject.audit.mixed_actors', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2', 'service_principal', '''test:fixture-worker'''), 3819, 'ck_batch_audit_actor_mode');

CALL c1_clone('reject.audit.unknown_from', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2', 'from_status', '''NO_MATCH'''), 3819, 'ck_batch_audit_from_state');

CALL c1_clone('reject.audit.unknown_to', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2', 'to_status', '''NO_MATCH'''), 3819, 'ck_batch_audit_to_state');

CALL c1_clone('reject.audit.zero_version', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2', 'batch_version', '0'), 3819, 'ck_batch_audit_version');

CALL c1_clone('reject.audit.zero_sequence', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '0'), 3819, 'ck_batch_audit_sequence');

CALL c1_clone('reject.audit.claim_pointer', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2', 'claim_id', '''c1269999-0000-4000-8000-000000000001'''), 3819, 'ck_batch_audit_c1_claim_null');

CALL c1_clone('reject.audit.assignment_pointer', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2', 'assignment_id', '''a1269999-0000-4000-8000-000000000001'''), 3819, 'ck_batch_audit_c1_assignment_null');

CALL c1_clone('reject.audit.unknown_batch', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2', 'batch_id', '''b1269999-0000-4000-8000-000000000001'''), 1452, 'fk_batch_audit_batch');

CALL c1_clone('reject.audit.unknown_command', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2', 'command_id', '''c1269999-0000-4000-8000-000000000001'''), 1452, 'fk_batch_audit_command');

CALL c1_clone('reject.audit.unknown_user', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2', 'actor_user_id', '''UNKNOWN'''), 1452, 'fk_batch_audit_actor');

CALL c1_clone('reject.audit.unknown_org', 'batch_audit_events', 'a1260001-0000-4000-8000-000000000003', 'a1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2', 'actor_org_id', '''UNKNOWN'''), 1452, 'fk_batch_audit_org');

CALL c1_clone('valid.outbox.valid_pending', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003'''), 0, '');

CALL c1_clone('valid.outbox.valid_published', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003''', 'publish_state', '''PUBLISHED''', 'next_attempt_at', 'NULL', 'published_at', '''2026-09-01 01:00:01.000000'''), 0, '');

CALL c1_clone('valid.outbox.valid_quarantined', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003''', 'publish_state', '''QUARANTINED''', 'next_attempt_at', 'NULL'), 0, '');

CALL c1_clone('reject.outbox.duplicate_command_event', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('sequence_in_command', '2'), 1062, 'uq_outbox_command_event');

CALL c1_clone('reject.outbox.duplicate_command_sequence', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('event_type', '''OtherTestEvent'''), 1062, 'uq_outbox_command_seq');

CALL c1_clone('reject.outbox.wrong_partition_key', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003''', 'partition_key', '''b1260000-0000-4000-8000-000000000004'''), 3819, 'ck_outbox_key');

-- Unknown state also violates the delivery-metadata shape check.
CALL c1_clone('reject.outbox.invalid_state', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003''', 'publish_state', '''SENT'''), 3819, 'ck_outbox_delivery_metadata');

CALL c1_clone('reject.outbox.zero_schema_version', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003''', 'schema_version', '0'), 3819, 'ck_outbox_schema_version');

CALL c1_clone('reject.outbox.zero_aggregate_version', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003''', 'aggregate_version', '0'), 3819, 'ck_outbox_aggregate_version');

CALL c1_clone('reject.outbox.zero_sequence', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003''', 'sequence_in_command', '0'), 3819, 'ck_outbox_sequence');

CALL c1_clone('reject.outbox.pending_without_next_attempt', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003''', 'next_attempt_at', 'NULL'), 3819, 'ck_outbox_delivery_metadata');

CALL c1_clone('reject.outbox.pending_with_published_at', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003''', 'published_at', '''2026-09-01 01:00:01.000000'''), 3819, 'ck_outbox_delivery_metadata');

CALL c1_clone('reject.outbox.published_without_time', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003''', 'publish_state', '''PUBLISHED''', 'next_attempt_at', 'NULL'), 3819, 'ck_outbox_delivery_metadata');

CALL c1_clone('reject.outbox.quarantined_with_next_attempt', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003''', 'publish_state', '''QUARANTINED'''), 3819, 'ck_outbox_delivery_metadata');

CALL c1_clone('reject.outbox.unknown_command', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1269999-0000-4000-8000-000000000001'''), 1452, 'fk_outbox_command');

CALL c1_clone('reject.outbox.unknown_batch', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003''', 'batch_id', '''b1269999-0000-4000-8000-000000000001''', 'partition_key', '''b1269999-0000-4000-8000-000000000001'''), 1452, 'fk_outbox_batch');

CALL c1_clone('reject.outbox.invalid_json', 'event_outbox', 'e1260000-0000-4000-8000-000000000003', 'e1269999-0000-4000-8000-000000000099',
    JSON_OBJECT('command_id', '''c1260000-0000-4000-8000-000000000003''', 'payload_json', '''{invalid'''), 3140, '');

CALL c1_statement('reject.delete.referenced_batch', 'DELETE FROM ewaste_batches WHERE id=''b1260000-0000-4000-8000-000000000003''', 1451, 'fk_');

CALL c1_statement('reject.delete.referenced_command', 'DELETE FROM command_idempotency WHERE id=''c1260001-0000-4000-8000-000000000003''', 1451, 'fk_');

CALL c1_statement('reject.delete.referenced_organisation', 'DELETE FROM organisations WHERE organisation_id=''DON-001''', 1451, 'fk_');

-- Defaults and updates are read back before rollback; SQL coercion is not API validation.
START TRANSACTION;
INSERT INTO ewaste_batches(id, organization_id, created_by)
VALUES('b1269999-0000-4000-8000-000000000098', 'DON-001', 'USR-003');
CALL c1_assert('valid.batch.database_defaults',
    (SELECT CONCAT_WS('/',status,version,claim_epoch,is_data_bearing,
        submitted_at IS NULL,current_claim_id IS NULL,current_assignment_id IS NULL,
        created_at IS NOT NULL,updated_at>=created_at)
     FROM ewaste_batches WHERE id='b1269999-0000-4000-8000-000000000098'),
    'DRAFT/1/1/0/1/1/1/1/1');
UPDATE ewaste_batches SET category='BATTERIES', quantity=2, estimated_weight_kg=1.23,
    version=version+1 WHERE id='b1269999-0000-4000-8000-000000000098';
CALL c1_assert('valid.batch.draft_edit_roundtrip',
    (SELECT CONCAT_WS('/',category,quantity,estimated_weight_kg,version,status)
     FROM ewaste_batches WHERE id='b1269999-0000-4000-8000-000000000098'), 'BATTERIES/2/1.23/2/DRAFT');
ROLLBACK;

DELIMITER $$
CREATE PROCEDURE c1_transaction(IN p_fail BOOLEAN)
BEGIN
    DECLARE observed INT DEFAULT 0;
    DECLARE message_value TEXT DEFAULT '';
    START TRANSACTION;
    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
            GET DIAGNOSTICS CONDITION 1 observed=MYSQL_ERRNO, message_value=MESSAGE_TEXT;
        INSERT INTO ewaste_batches(id, organization_id, created_by, category, quantity,
            estimated_weight_kg, condition_rating, is_data_bearing, zone, collection_deadline,
            created_at, updated_at)
        VALUES('b1269999-0000-4000-8000-000000000090','DON-001','USR-003','BATTERIES',2,
            1.23,'REPAIRABLE',FALSE,'NORTH','2026-09-03 01:00:00.000000',
            '2026-09-01 00:00:00.000000','2026-09-01 00:00:00.000000');
        INSERT INTO command_idempotency(id,actor_user_id,actor_scope,command_name,
            idempotency_key,request_hash,batch_id,created_at,retain_until)
        VALUES('c1269999-0000-4000-8000-000000000090','USR-003','user:USR-003','FixtureSubmit',
            'c1-transaction',SHA2('c1-transaction',256),'b1269999-0000-4000-8000-000000000090',
            '2026-09-01 01:00:00.000000','2027-09-01 00:00:00.000000');
        UPDATE ewaste_batches SET status='SUBMITTED',version=version+1,
            submitted_at='2026-09-01 01:00:00.000000',updated_at='2026-09-01 01:00:00.000000'
        WHERE id='b1269999-0000-4000-8000-000000000090' AND status='DRAFT' AND version=1;
        INSERT INTO batch_audit_events(id,batch_id,command_id,actor_user_id,actor_org_id,event_type,
            from_status,to_status,batch_version,sequence_in_command,occurred_at,correlation_id,details_json)
        VALUES('a1269999-0000-4000-8000-000000000090','b1269999-0000-4000-8000-000000000090',
            'c1269999-0000-4000-8000-000000000090','USR-003','DON-001','RequestSubmitted',
            'DRAFT','SUBMITTED',2,1,'2026-09-01 01:00:00.000000','c1-transaction',JSON_OBJECT('operation','SUBMIT'));
        INSERT INTO event_outbox(event_id,batch_id,command_id,event_type,topic,schema_version,
            aggregate_version,sequence_in_command,partition_key,payload_json,correlation_id,
            occurred_at,created_at,next_attempt_at)
        SELECT 'e1269999-0000-4000-8000-000000000090','b1269999-0000-4000-8000-000000000090',
            'c1269999-0000-4000-8000-000000000090',event_type,topic,schema_version,2,1,
            IF(p_fail,'wrong-key','b1269999-0000-4000-8000-000000000090'),
            JSON_SET(payload_json,'$.event_id','e1269999-0000-4000-8000-000000000090',
                '$.command_id','c1269999-0000-4000-8000-000000000090',
                '$.batch_id','b1269999-0000-4000-8000-000000000090',
                '$.correlation_id','c1-transaction','$.data.category','BATTERIES',
                '$.data.quantity',2,'$.data.estimated_weight_kg','1.23',
                '$.data.condition_rating','REPAIRABLE'),
            'c1-transaction',occurred_at,created_at,next_attempt_at
        FROM event_outbox WHERE event_id='e1260000-0000-4000-8000-000000000003';
        UPDATE command_idempotency SET state='COMPLETED',response_status=200,
            response_json=JSON_OBJECT('batchId','b1269999-0000-4000-8000-000000000090',
                'status','SUBMITTED','version',2,'eventId','e1269999-0000-4000-8000-000000000090'),
            completed_at='2026-09-01 01:00:00.000000'
        WHERE id='c1269999-0000-4000-8000-000000000090';
    END;
    IF observed<>0 OR p_fail THEN ROLLBACK; ELSE COMMIT; END IF;
    CALL c1_assert(IF(p_fail,'transaction.forced_failure','transaction.success'),
        CAST(observed AS CHAR), IF(p_fail,'3819','0'));
    IF p_fail THEN
        CALL c1_assert('transaction.failure_is_outbox_constraint',
            CAST(LOCATE('ck_outbox_key',message_value)>0 AS CHAR),'1');
    END IF;
END$$
DELIMITER ;
CALL c1_transaction(TRUE);

CALL c1_assert('transaction.rollback_ewaste_batches', CAST((SELECT COUNT(*) FROM ewaste_batches) AS CHAR), '7');

CALL c1_assert('transaction.rollback_command_idempotency', CAST((SELECT COUNT(*) FROM command_idempotency) AS CHAR), '12');

CALL c1_assert('transaction.rollback_batch_audit_events', CAST((SELECT COUNT(*) FROM batch_audit_events) AS CHAR), '12');

CALL c1_assert('transaction.rollback_event_outbox', CAST((SELECT COUNT(*) FROM event_outbox) AS CHAR), '5');

CALL c1_transaction(FALSE);

CALL c1_assert('transaction.committed_all_four_tables', CAST((SELECT COUNT(*) FROM ewaste_batches b JOIN command_idempotency c ON c.batch_id=b.id JOIN batch_audit_events a ON a.command_id=c.id AND a.batch_id=b.id JOIN event_outbox e ON e.command_id=c.id AND e.batch_id=b.id WHERE b.id='b1269999-0000-4000-8000-000000000090' AND b.status='SUBMITTED' AND b.version=2 AND c.state='COMPLETED' AND c.response_status=200 AND JSON_UNQUOTE(JSON_EXTRACT(c.response_json,'$.eventId'))=e.event_id AND a.batch_version=2 AND e.aggregate_version=2 AND e.publish_state='PENDING') AS CHAR), '1');

CALL c1_assert('transaction.final_ewaste_batches', CAST((SELECT COUNT(*) FROM ewaste_batches) AS CHAR), '8');

CALL c1_assert('transaction.final_command_idempotency', CAST((SELECT COUNT(*) FROM command_idempotency) AS CHAR), '13');

CALL c1_assert('transaction.final_batch_audit_events', CAST((SELECT COUNT(*) FROM batch_audit_events) AS CHAR), '13');

CALL c1_assert('transaction.final_event_outbox', CAST((SELECT COUNT(*) FROM event_outbox) AS CHAR), '6');

SELECT test_name,result,actual,expected FROM c1_results ORDER BY sequence_id;
CALL c1_finish();
DROP PROCEDURE c1_transaction;
DROP PROCEDURE c1_clone;
DROP PROCEDURE c1_statement;
DROP PROCEDURE c1_assert;
DROP PROCEDURE c1_finish;
DROP TEMPORARY TABLE c1_results;
PERSISTENCE_EMBED_005

  mkdir -p "$WORK_DIR/database/tests/c3"
  # Embedded database/tests/c3/changelog-c3.yaml
  cat > "$WORK_DIR/database/tests/c3/changelog-c3.yaml" <<'PERSISTENCE_EMBED_006'
# Frozen C3 test boundary; original Liquibase file identities are preserved.
databaseChangeLog:
  - include:
      file: changes/001-create-organisations.sql
  - include:
      file: changes/002-create-roles.sql
  - include:
      file: changes/003-create-users.sql
  - include:
      file: changes/004-create-sessions.sql
  - include:
      file: changes/005-create-login-audit.sql
  - include:
      file: changes/006-create-ewaste-batches.sql
  - include:
      file: changes/007-add-ewaste-batch-constraints.sql
  - include:
      file: changes/008-create-command-idempotency.sql
  - include:
      file: changes/009-create-batch-audit-events.sql
  - include:
      file: changes/010-create-event-outbox.sql
  - include:
      file: changes/011-create-matching-rule-sets.sql
  - include:
      file: changes/012-create-recycler-matching-profiles.sql
  - include:
      file: changes/013-create-recycler-capacity-pools.sql
  - include:
      file: changes/014-create-recycler-category-capabilities.sql
  - include:
      file: changes/015-create-recycler-service-zones.sql
  - include:
      file: changes/016-create-matching-decisions.sql
  - include:
      file: changes/017-create-matched-results.sql
  - include:
      file: changes/018-create-batch-claims.sql
  - include:
      file: changes/019-create-capacity-reservations.sql
  - include:
      file: changes/020-link-current-claim-and-audit.sql
  - include:
      file: seed/101-seed-organisations.sql
  - include:
      file: seed/102-seed-roles.sql
  - include:
      file: seed/103-seed-users.sql
  - include:
      file: seed/104-seed-c1-batches.sql
PERSISTENCE_EMBED_006

  mkdir -p "$WORK_DIR/database/tests/c3"
  # Embedded database/tests/c3/schema-fixtures.sql
  cat > "$WORK_DIR/database/tests/c3/schema-fixtures.sql" <<'PERSISTENCE_EMBED_007'
-- Test-only, deterministic C3 records. Requires migrations 001-020 and @seed.
-- Run once in a disposable database. These are row-constraint fixtures, not
-- evidence of an application command, matching execution or authentication.
SET NAMES utf8mb4;
SET time_zone = '+00:00';
START TRANSACTION;
INSERT INTO recycler_capacity_pools
    (id, recycler_org_id, pool_code, total_kg, reserved_kg, is_active, version, updated_at)
VALUES
    ('d3000000-0000-4000-8000-000000000001', 'PROC-001', 'C3-CONSTRAINTS', 1000, 100, 1, 2, '2026-09-18 10:00:00.000000');

INSERT INTO ewaste_batches
    (id, organization_id, created_by, status, category, quantity,
     estimated_weight_kg, condition_rating, is_data_bearing, zone,
     collection_deadline, claim_epoch, version, submitted_at, created_at, updated_at)
VALUES
    ('b3000000-0000-4000-8000-000000000001', 'DON-001', 'USR-003', 'MATCHED',
     'ICT_EQUIPMENT', 5, 100, 'REPAIRABLE', 1, 'CENTRAL', '2026-09-25 10:00:00.000000',
     1, 3, '2026-09-17 10:00:00.000000', '2026-09-17 09:00:00.000000', '2026-09-18 09:00:00.000000'),
    ('b3000000-0000-4000-8000-000000000002', 'DON-001', 'USR-003', 'MATCHED',
     'ICT_EQUIPMENT', 5, 100, 'REPAIRABLE', 1, 'CENTRAL', '2026-09-25 10:00:00.000000',
     1, 3, '2026-09-17 10:00:00.000000', '2026-09-17 09:00:00.000000', '2026-09-18 09:00:00.000000');

INSERT INTO batch_claims
    (id, batch_id, claim_epoch, recycler_org_id, claimed_by, claim_status,
     idempotency_key, claimed_at, created_at)
VALUES
    ('f3000000-0000-4000-8000-000000000001', 'b3000000-0000-4000-8000-000000000001',
     1, 'PROC-001', 'USR-007', 'ACCEPTED', 'C3-Schema-Winner-0001',
     '2026-09-18 10:00:00.000000', '2026-09-18 10:00:00.000000');

INSERT INTO capacity_reservations
    (id, batch_id, claim_id, capacity_pool_id, reserved_kg, status, reserved_at, version)
VALUES
    ('a3000000-0000-4000-8000-000000000001', 'b3000000-0000-4000-8000-000000000001',
     'f3000000-0000-4000-8000-000000000001', 'd3000000-0000-4000-8000-000000000001',
     100, 'RESERVED', '2026-09-18 10:00:00.000000', 1);

UPDATE ewaste_batches SET status='APPROVED', version=4,
    current_claim_id='f3000000-0000-4000-8000-000000000001',
    updated_at='2026-09-18 10:00:00.000000'
WHERE id='b3000000-0000-4000-8000-000000000001';

INSERT INTO command_idempotency
    (id, actor_user_id, actor_scope, command_name, idempotency_key, request_hash,
     batch_id, state, response_status, response_json, created_at, completed_at, retain_until)
VALUES
    ('c3000000-0000-4000-8000-000000000001', 'USR-007', 'user:USR-007',
     'ClaimOpportunity', 'C3-Schema-Winner-0001', SHA2('schema-fixture-only',256),
     'b3000000-0000-4000-8000-000000000001', 'COMPLETED', 200,
     JSON_OBJECT('claim_id','f3000000-0000-4000-8000-000000000001',
                 'batch_id','b3000000-0000-4000-8000-000000000001',
                 'recycler_org_id','PROC-001','claim_epoch','1','status','ACCEPTED',
                 'batch_status','APPROVED','claimed_at','2026-09-18T10:00:00.000000Z',
                 'correlation_id','c3-schema-fixture'),
     '2026-09-18 10:00:00.000000','2026-09-18 10:00:00.000000','2027-09-18 10:00:00.000000');

INSERT INTO batch_audit_events
    (id, batch_id, command_id, claim_id, actor_user_id, actor_org_id, event_type,
     from_status, to_status, batch_version, sequence_in_command, occurred_at,
     correlation_id, details_json)
VALUES
    ('e3000000-0000-4000-8000-000000000001','b3000000-0000-4000-8000-000000000001',
     'c3000000-0000-4000-8000-000000000001','f3000000-0000-4000-8000-000000000001',
     'USR-007','PROC-001','ClaimConfirmed','MATCHED','APPROVED',4,1,
     '2026-09-18 10:00:00.000000','c3-schema-fixture',JSON_OBJECT('fixture','row-constraints'));

INSERT INTO event_outbox
    (event_id,batch_id,command_id,event_type,topic,schema_version,aggregate_version,
     sequence_in_command,partition_key,payload_json,correlation_id,occurred_at,
     created_at,publish_state,attempt_count,next_attempt_at)
VALUES
    ('e3000001-0000-4000-8000-000000000001','b3000000-0000-4000-8000-000000000001',
     'c3000000-0000-4000-8000-000000000001','ClaimConfirmed','ewaste.claim.events',1,4,1,
     'b3000000-0000-4000-8000-000000000001',
     JSON_OBJECT('event_id','e3000001-0000-4000-8000-000000000001','event_type','ClaimConfirmed',
       'schema_version',1,'command_id','c3000000-0000-4000-8000-000000000001',
       'batch_id','b3000000-0000-4000-8000-000000000001','batch_version',4,'claim_epoch','1',
       'sequence_in_command',1,'occurred_at','2026-09-18T10:00:00.000000Z',
       'correlation_id','c3-schema-fixture','data',JSON_OBJECT(
         'claim_id','f3000000-0000-4000-8000-000000000001','recycler_org_id','PROC-001',
         'actor_user_id','USR-007','claimed_at','2026-09-18T10:00:00.000000Z')),
     'c3-schema-fixture','2026-09-18 10:00:00.000000','2026-09-18 10:00:00.000000',
     'PENDING',0,'2026-09-18 10:00:00.000000');
COMMIT;
PERSISTENCE_EMBED_007

  mkdir -p "$WORK_DIR/database/tests/c3"
  # Embedded database/tests/c3/verify-schema.sql
  cat > "$WORK_DIR/database/tests/c3/verify-schema.sql" <<'PERSISTENCE_EMBED_008'
-- C3 runtime checks. Run only in the runner's disposable MySQL database.
-- All mutation checks roll back; load schema-fixtures.sql first.
-- Expected errors include the exact MySQL error number and named constraint.
SET NAMES utf8mb4;
SET time_zone = '+00:00';
SET SESSION group_concat_max_len = 16384;
CREATE TEMPORARY TABLE c3_results (
    sequence_id INT AUTO_INCREMENT PRIMARY KEY,
    test_name VARCHAR(128) NOT NULL UNIQUE,
    result VARCHAR(4) NOT NULL,
    actual VARCHAR(4096),
    expected VARCHAR(4096)
) ENGINE=MEMORY;
DELIMITER $$
CREATE PROCEDURE c3_assert(IN p_name VARCHAR(128), IN p_actual TEXT, IN p_expected TEXT)
BEGIN
    INSERT INTO c3_results(test_name, result, actual, expected)
    VALUES(p_name, IF(BINARY p_actual <=> BINARY p_expected, 'PASS', 'FAIL'), p_actual, p_expected);
END$$
CREATE PROCEDURE c3_statement(
    IN p_name VARCHAR(128), IN p_sql LONGTEXT,
    IN p_errno INT, IN p_constraint VARCHAR(128))
BEGIN
    DECLARE observed INT DEFAULT 0;
    DECLARE message_text_value TEXT DEFAULT '';
    DECLARE affected INT DEFAULT 0;
    DECLARE prepared_ok BOOLEAN DEFAULT FALSE;
    START TRANSACTION;
    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
            GET DIAGNOSTICS CONDITION 1 observed = MYSQL_ERRNO, message_text_value = MESSAGE_TEXT;
        SET @c3_statement = p_sql;
        PREPARE c3_prepared FROM @c3_statement;
        SET prepared_ok = TRUE;
        EXECUTE c3_prepared;
        SET affected = ROW_COUNT();
    END;
    IF prepared_ok THEN DEALLOCATE PREPARE c3_prepared; END IF;
    ROLLBACK;
    INSERT INTO c3_results(test_name, result, actual, expected)
    VALUES(p_name,
        IF(observed = p_errno
           AND (p_errno <> 0 OR affected = 1)
           AND (p_constraint = '' OR LOCATE(p_constraint, message_text_value) > 0), 'PASS', 'FAIL'),
        IF(observed = 0, CONCAT('accepted rows=', affected), CONCAT(observed, ': ', message_text_value)),
        IF(p_errno = 0, 'accepted rows=1', CONCAT(p_errno, ': ', p_constraint)));
END$$
CREATE PROCEDURE c3_clone(
    IN p_name VARCHAR(128), IN p_table VARCHAR(64), IN p_source VARCHAR(36),
    IN p_id VARCHAR(36), IN p_patch JSON, IN p_errno INT, IN p_constraint VARCHAR(128))
BEGIN
    DECLARE columns_sql TEXT;
    DECLARE values_sql TEXT;
    DECLARE pk_name VARCHAR(16);
    IF p_table NOT IN ('batch_claims','capacity_reservations','ewaste_batches','command_idempotency','batch_audit_events','event_outbox') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid test table';
    END IF;
    SET pk_name = IF(p_table = 'event_outbox', 'event_id', 'id');
    SELECT GROUP_CONCAT(CONCAT('`', COLUMN_NAME, '`') ORDER BY ORDINAL_POSITION),
           GROUP_CONCAT(CASE
               WHEN JSON_CONTAINS_PATH(p_patch, 'one', CONCAT('$.', COLUMN_NAME))
                   THEN JSON_UNQUOTE(JSON_EXTRACT(p_patch, CONCAT('$.', COLUMN_NAME)))
               WHEN COLUMN_NAME = pk_name THEN QUOTE(p_id)
               ELSE CONCAT('b.`', COLUMN_NAME, '`') END ORDER BY ORDINAL_POSITION)
    INTO columns_sql, values_sql
    FROM information_schema.columns WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table;
    CALL c3_statement(p_name,
        CONCAT('INSERT INTO ', p_table, ' (', columns_sql, ') SELECT ', values_sql,
               ' FROM ', p_table, ' b WHERE b.', pk_name, ' = ', QUOTE(p_source)),
        p_errno, p_constraint);
END$$
CREATE PROCEDURE c3_finish()
BEGIN
    IF EXISTS(SELECT 1 FROM c3_results WHERE result <> 'PASS') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C3 persistence check failed';
    END IF;
END$$
DELIMITER ;



CALL c3_assert('schema.batch_claims.columns', CAST((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='batch_claims') AS CHAR), '11');

CALL c3_assert('schema.batch_claims.engine', CAST((SELECT CONCAT(engine,'/',table_collation) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='batch_claims') AS CHAR), 'InnoDB/utf8mb4_0900_ai_ci');

CALL c3_assert('schema.capacity_reservations.columns', CAST((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='capacity_reservations') AS CHAR), '11');

CALL c3_assert('schema.capacity_reservations.engine', CAST((SELECT CONCAT(engine,'/',table_collation) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='capacity_reservations') AS CHAR), 'InnoDB/utf8mb4_0900_ai_ci');

CALL c3_assert('schema.batch_claims.claim_epoch', CAST((SELECT CONCAT(column_type,'/',is_nullable) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='batch_claims' AND column_name='claim_epoch') AS CHAR), 'bigint unsigned/NO');

CALL c3_assert('schema.capacity_reservations.version', CAST((SELECT CONCAT(column_type,'/',is_nullable) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='capacity_reservations' AND column_name='version') AS CHAR), 'bigint/NO');

CALL c3_assert('schema.capacity_reservations.reserved_kg', CAST((SELECT CONCAT(column_type,'/',is_nullable) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='capacity_reservations' AND column_name='reserved_kg') AS CHAR), 'decimal(8,2)/NO');

CALL c3_assert('collation.batch_claims.idempotency_key', CAST((SELECT collation_name FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='batch_claims' AND column_name='idempotency_key') AS CHAR), 'utf8mb4_0900_ai_ci');

CALL c3_assert('collation.command_idempotency.idempotency_key', CAST((SELECT collation_name FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='command_idempotency' AND column_name='idempotency_key') AS CHAR), 'utf8mb4_0900_as_cs');

CALL c3_assert('collation.batch_claims.claim_status', CAST((SELECT collation_name FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='batch_claims' AND column_name='claim_status') AS CHAR), 'utf8mb4_0900_as_cs');

CALL c3_assert('collation.capacity_reservations.status', CAST((SELECT collation_name FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='capacity_reservations' AND column_name='status') AS CHAR), 'utf8mb4_0900_as_cs');

CALL c3_assert('unique.uk_batch_claim_epoch', CAST((SELECT CONCAT(MIN(non_unique),':',GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='batch_claims' AND index_name='uk_batch_claim_epoch') AS CHAR), '0:batch_id,claim_epoch');

CALL c3_assert('unique.uk_claim_idempotency', CAST((SELECT CONCAT(MIN(non_unique),':',GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='batch_claims' AND index_name='uk_claim_idempotency') AS CHAR), '0:idempotency_key');

CALL c3_assert('unique.uq_claim_id_batch', CAST((SELECT CONCAT(MIN(non_unique),':',GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='batch_claims' AND index_name='uq_claim_id_batch') AS CHAR), '0:id,batch_id');

CALL c3_assert('unique.uq_claim_id_batch_epoch', CAST((SELECT CONCAT(MIN(non_unique),':',GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='batch_claims' AND index_name='uq_claim_id_batch_epoch') AS CHAR), '0:id,batch_id,claim_epoch');

CALL c3_assert('unique.uq_reservation_claim', CAST((SELECT CONCAT(MIN(non_unique),':',GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='capacity_reservations' AND index_name='uq_reservation_claim') AS CHAR), '0:claim_id');

CALL c3_assert('foreign_key.fk_batches_current_claim', CAST((SELECT GROUP_CONCAT(CONCAT(column_name,'>',referenced_column_name) ORDER BY ordinal_position) FROM information_schema.key_column_usage WHERE constraint_schema=DATABASE() AND constraint_name='fk_batches_current_claim') AS CHAR), 'current_claim_id>id,id>batch_id,claim_epoch>claim_epoch');

CALL c3_assert('foreign_key.fk_batch_audit_claim_batch', CAST((SELECT GROUP_CONCAT(CONCAT(column_name,'>',referenced_column_name) ORDER BY ordinal_position) FROM information_schema.key_column_usage WHERE constraint_schema=DATABASE() AND constraint_name='fk_batch_audit_claim_batch') AS CHAR), 'claim_id>id,batch_id>batch_id');

CALL c3_assert('foreign_key.fk_reservation_claim_batch', CAST((SELECT GROUP_CONCAT(CONCAT(column_name,'>',referenced_column_name) ORDER BY ordinal_position) FROM information_schema.key_column_usage WHERE constraint_schema=DATABASE() AND constraint_name='fk_reservation_claim_batch') AS CHAR), 'claim_id>id,batch_id>batch_id');

CALL c3_assert('foreign_keys.restrict', CAST((SELECT COUNT(*) FROM information_schema.referential_constraints WHERE constraint_schema=DATABASE() AND (table_name IN ('batch_claims','capacity_reservations') OR constraint_name IN ('fk_batches_current_claim','fk_batch_audit_claim_batch')) AND delete_rule IN ('RESTRICT','NO ACTION') AND update_rule IN ('RESTRICT','NO ACTION')) AS CHAR), '9');

CALL c3_assert('staging.assignment_null_retained', CAST((SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_schema=DATABASE() AND constraint_name IN ('ck_batches_c1_assignment_null','ck_command_c1_assignment_null','ck_batch_audit_c1_assignment_null') AND enforced='YES') AS CHAR), '3');

CALL c3_assert('staging.claim_null_replaced', CAST((SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_schema=DATABASE() AND constraint_name IN ('ck_batches_c1_claim_null','ck_batch_audit_c1_claim_null')) AS CHAR), '0');

CALL c3_clone('claim.valid_second_batch', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002'''), 0, '');

CALL c3_clone('claim.duplicate_epoch', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000001''','idempotency_key','''C3-Fresh-Key-000002'''), 1062, 'uk_batch_claim_epoch');

CALL c3_clone('claim.duplicate_global_key', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Schema-Winner-0001'''), 1062, 'uk_claim_idempotency');

CALL c3_clone('claim.case_only_key', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''c3-schema-winner-0001'''), 1062, 'uk_claim_idempotency');

CALL c3_clone('claim.cross_actor_global_key', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Schema-Winner-0001''','claimed_by','''USR-008''','recycler_org_id','''PROC-002'''), 1062, 'uk_claim_idempotency');

CALL c3_clone('claim.orphan_batch_id', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''missing-parent''','idempotency_key','''C3-Fresh-Key-000002'''), 1452, 'fk_batch_claims_batch');

CALL c3_clone('claim.orphan_recycler_org_id', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002''','recycler_org_id','''missing-parent'''), 1452, 'fk_batch_claims_org');

CALL c3_clone('claim.orphan_claimed_by', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002''','claimed_by','''missing-parent'''), 1452, 'fk_batch_claims_user');

CALL c3_clone('claim.rejected_claim_epoch_31', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002''','claim_epoch','0'), 3819, 'ck_claim_epoch');

CALL c3_clone('claim.rejected_claim_status_32', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002''','claim_status','''accepted'''), 3819, 'chk_claim_status');

CALL c3_clone('claim.rejected_claim_status_33', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002''','claim_status','''INVALID'''), 3819, 'chk_claim_status');

CALL c3_clone('claim.rejected_idempotency_key_34', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''short'''), 3819, 'ck_claim_key_length');

CALL c3_clone('claim.rejected_created_at_35', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002''','created_at','''2026-09-17 00:00:00'''), 3819, 'ck_claim_created_time');

CALL c3_clone('claim.rejected_superseded_at_36', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002''','superseded_at','''2026-09-19 00:00:00'''), 3819, 'ck_claim_superseded_time');

CALL c3_clone('claim.rejected_claim_status_37', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002''','claim_status','''SUPERSEDED'''), 3819, 'ck_claim_superseded_time');

CALL c3_clone('claim.null_required', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002''','claimed_by','NULL'), 1048, 'claimed_by');

CALL c3_clone('claim.valid_superseded_vocabulary', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002''','claim_status','''SUPERSEDED''','superseded_at','''2026-09-18 10:00:00'''), 0, '');

CALL c3_clone('claim.valid_rejected_vocabulary', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002''','claim_status','''REJECTED'''), 0, '');

CALL c3_clone('claim.superseded_before_claim', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002''','claim_status','''SUPERSEDED''','superseded_at','''2026-09-17 10:00:00'''), 3819, 'ck_claim_superseded_time');

CALL c3_clone('claim.notes_255_unicode', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''C3-Fresh-Key-000002''','notes','REPEAT(''界'',255)'), 0, '');

CALL c3_clone('claim.key_16', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','''1234567890abcdef'''), 0, '');

CALL c3_clone('claim.key_64', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','REPEAT(''k'',64)'), 0, '');

CALL c3_clone('claim.key_65', 'batch_claims', 'f3000000-0000-4000-8000-000000000001', 'f3999999-0000-4000-8000-000000000099', JSON_OBJECT('batch_id','''b3000000-0000-4000-8000-000000000002''','idempotency_key','REPEAT(''k'',65)'), 1406, 'idempotency_key');

CALL c3_clone('reservation.duplicate_claim', 'capacity_reservations', 'a3000000-0000-4000-8000-000000000001', 'a3999999-0000-4000-8000-000000000099', JSON_OBJECT(), 1062, 'uq_reservation_claim');

CALL c3_statement('reservation.cross_batch', 'UPDATE capacity_reservations SET batch_id=''b3000000-0000-4000-8000-000000000002'' WHERE id=''a3000000-0000-4000-8000-000000000001''', 1452, 'fk_reservation_claim_batch');

CALL c3_statement('reservation.orphan_claim', 'UPDATE capacity_reservations SET claim_id=''missing-claim'' WHERE id=''a3000000-0000-4000-8000-000000000001''', 1452, 'fk_reservation_claim_batch');

CALL c3_statement('reservation.orphan_pool', 'UPDATE capacity_reservations SET capacity_pool_id=''missing-pool'' WHERE id=''a3000000-0000-4000-8000-000000000001''', 1452, 'fk_reservation_pool');

CALL c3_statement('reservation.weight_zero', 'UPDATE capacity_reservations SET reserved_kg=0 WHERE id=''a3000000-0000-4000-8000-000000000001''', 3819, 'ck_reservation_weight');

CALL c3_statement('reservation.weight_too_large', 'UPDATE capacity_reservations SET reserved_kg=50000.01 WHERE id=''a3000000-0000-4000-8000-000000000001''', 3819, 'ck_reservation_weight');

CALL c3_statement('reservation.version_zero', 'UPDATE capacity_reservations SET version=0 WHERE id=''a3000000-0000-4000-8000-000000000001''', 3819, 'ck_reservation_version');

CALL c3_statement('reservation.case_status_release_guard', 'UPDATE capacity_reservations SET status=''reserved'' WHERE id=''a3000000-0000-4000-8000-000000000001''', 3819, 'ck_reservation_release');

CALL c3_statement('reservation.release_missing_fields', 'UPDATE capacity_reservations SET status=''RELEASED'' WHERE id=''a3000000-0000-4000-8000-000000000001''', 3819, 'ck_reservation_release');

CALL c3_statement('reservation.reserved_release_time', 'UPDATE capacity_reservations SET released_at=''2026-09-19 10:00:00'' WHERE id=''a3000000-0000-4000-8000-000000000001''', 3819, 'ck_reservation_release');

CALL c3_statement('reservation.reserved_release_reason', 'UPDATE capacity_reservations SET release_reason=''reason'' WHERE id=''a3000000-0000-4000-8000-000000000001''', 3819, 'ck_reservation_release');

CALL c3_statement('reservation.reserved_release_command', 'UPDATE capacity_reservations SET release_command_id=''c3000000-0000-4000-8000-000000000001'' WHERE id=''a3000000-0000-4000-8000-000000000001''', 3819, 'ck_reservation_release');

CALL c3_statement('reservation.minimum_weight', 'UPDATE capacity_reservations SET reserved_kg=0.10 WHERE id=''a3000000-0000-4000-8000-000000000001''', 0, '');

CALL c3_statement('reservation.maximum_weight', 'UPDATE capacity_reservations SET reserved_kg=50000.00 WHERE id=''a3000000-0000-4000-8000-000000000001''', 0, '');

CALL c3_statement('reservation.valid_release_vocabulary', 'UPDATE capacity_reservations SET status=''RELEASED'',released_at=''2026-09-19 10:00:00'',release_reason=''Fixture release'',release_command_id=''c3000000-0000-4000-8000-000000000001'' WHERE id=''a3000000-0000-4000-8000-000000000001''', 0, '');

CALL c3_statement('reservation.release_blank_reason', 'UPDATE capacity_reservations SET status=''RELEASED'',released_at=''2026-09-19 10:00:00'',release_reason=''   '',release_command_id=''c3000000-0000-4000-8000-000000000001'' WHERE id=''a3000000-0000-4000-8000-000000000001''', 3819, 'ck_reservation_release');

CALL c3_statement('reservation.release_before_reservation', 'UPDATE capacity_reservations SET status=''RELEASED'',released_at=''2026-09-17 10:00:00'',release_reason=''Fixture release'',release_command_id=''c3000000-0000-4000-8000-000000000001'' WHERE id=''a3000000-0000-4000-8000-000000000001''', 3819, 'ck_reservation_release');

CALL c3_statement('reservation.release_orphan_command', 'UPDATE capacity_reservations SET status=''RELEASED'',released_at=''2026-09-19 10:00:00'',release_reason=''Fixture release'',release_command_id=''missing-command'' WHERE id=''a3000000-0000-4000-8000-000000000001''', 1452, 'fk_reservation_release_command');

CALL c3_statement('pointer.wrong_batch', 'UPDATE ewaste_batches SET status=''APPROVED'',current_claim_id=''f3000000-0000-4000-8000-000000000001'' WHERE id=''b3000000-0000-4000-8000-000000000002''', 1452, 'fk_batches_current_claim');

CALL c3_statement('pointer.wrong_epoch', 'UPDATE ewaste_batches SET claim_epoch=2 WHERE id=''b3000000-0000-4000-8000-000000000001''', 1452, 'fk_batches_current_claim');

CALL c3_statement('pointer.approved_requires_claim', 'UPDATE ewaste_batches SET current_claim_id=NULL WHERE id=''b3000000-0000-4000-8000-000000000001''', 3819, 'ck_batches_claim_state');

CALL c3_statement('pointer.matched_forbids_claim', 'UPDATE ewaste_batches SET status=''MATCHED'' WHERE id=''b3000000-0000-4000-8000-000000000001''', 3819, 'ck_batches_claim_state');

CALL c3_statement('audit.wrong_batch', 'UPDATE batch_audit_events SET batch_id=''b3000000-0000-4000-8000-000000000002'' WHERE id=''e3000000-0000-4000-8000-000000000001''', 1452, 'fk_batch_audit_claim_batch');

CALL c3_statement('batch.assignment_still_null', 'UPDATE ewaste_batches SET current_assignment_id=''11111111-1111-4111-8111-111111111111'' WHERE id=''b3000000-0000-4000-8000-000000000001''', 3819, 'ck_batches_c1_assignment_null');

CALL c3_statement('audit.assignment_still_null', 'UPDATE batch_audit_events SET assignment_id=''11111111-1111-4111-8111-111111111111'' WHERE id=''e3000000-0000-4000-8000-000000000001''', 3819, 'ck_batch_audit_c1_assignment_null');

CALL c3_statement('claim.history_restrict', 'DELETE FROM batch_claims WHERE id=''f3000000-0000-4000-8000-000000000001''', 1451, '');

CALL c3_statement('pool.history_restrict', 'DELETE FROM recycler_capacity_pools WHERE id=''d3000000-0000-4000-8000-000000000001''', 1451, 'fk_reservation_pool');

CALL c3_clone('command.exact_scope_duplicate', 'command_idempotency', 'c3000000-0000-4000-8000-000000000001', 'c3999999-0000-4000-8000-000000000099', JSON_OBJECT(), 1062, 'uq_command_replay');

CALL c3_clone('command.case_sensitive_key', 'command_idempotency', 'c3000000-0000-4000-8000-000000000001', 'c3999999-0000-4000-8000-000000000099', JSON_OBJECT('idempotency_key','''c3-schema-winner-0001'''), 0, '');

CALL c3_clone('command.separate_actor_scope', 'command_idempotency', 'c3000000-0000-4000-8000-000000000001', 'c3999999-0000-4000-8000-000000000099', JSON_OBJECT('actor_user_id','''USR-008''','actor_scope','''user:USR-008'''), 0, '');

CALL c3_assert('schema.reservation_checks', CAST((SELECT GROUP_CONCAT(constraint_name ORDER BY constraint_name) FROM information_schema.table_constraints WHERE constraint_schema=DATABASE() AND table_name='capacity_reservations' AND constraint_type='CHECK' AND enforced='YES') AS CHAR), 'ck_reservation_release,ck_reservation_status,ck_reservation_version,ck_reservation_weight');

CALL c3_assert('schema.claim_checks', CAST((SELECT GROUP_CONCAT(constraint_name ORDER BY constraint_name) FROM information_schema.table_constraints WHERE constraint_schema=DATABASE() AND table_name='batch_claims' AND constraint_type='CHECK' AND enforced='YES') AS CHAR), 'chk_claim_status,ck_claim_created_time,ck_claim_epoch,ck_claim_key_length,ck_claim_superseded_time');

SELECT test_name,result,actual,expected FROM c3_results ORDER BY sequence_id;

CALL c3_finish();

DROP PROCEDURE c3_clone;

DROP PROCEDURE c3_statement;

DROP PROCEDURE c3_assert;

DROP PROCEDURE c3_finish;

DROP TEMPORARY TABLE c3_results;
PERSISTENCE_EMBED_008

  mkdir -p "$WORK_DIR/database/tests/c4"
  # Embedded database/tests/c4/schema-fixtures.sql
  cat > "$WORK_DIR/database/tests/c4/schema-fixtures.sql" <<'PERSISTENCE_EMBED_009'
-- Deterministic row-constraint fixtures, run once on the runner's disposable DB.
-- Requires @seed plus tests/c3/schema-fixtures.sql and C4 migrations.
-- Application lifecycle evidence is produced separately through the Go repository.
SET NAMES utf8mb4;
SET time_zone = '+00:00';
START TRANSACTION;
INSERT INTO recycler_collector_scopes
    (id,recycler_org_id,collector_org_id,zone,is_active,version,valid_from,valid_until,created_at,updated_at)
VALUES
    ('54000000-0000-4000-8000-000000000001','PROC-001','COL-001','CENTRAL',1,1,'2026-09-01',NULL,'2026-09-01','2026-09-01'),
    ('54000000-0000-4000-8000-000000000002','PROC-001','COL-002','CENTRAL',1,1,'2026-09-01',NULL,'2026-09-01','2026-09-01');

INSERT INTO batch_claims
    (id,batch_id,claim_epoch,recycler_org_id,claimed_by,claim_status,idempotency_key,claimed_at,created_at)
VALUES ('f3000000-0000-4000-8000-000000000002','b3000000-0000-4000-8000-000000000002',1,
    'PROC-001','USR-007','ACCEPTED','C4-Schema-Claim-0002','2026-09-18 10:00:00','2026-09-18 10:00:00');
INSERT INTO capacity_reservations
    (id,batch_id,claim_id,capacity_pool_id,reserved_kg,status,reserved_at,version)
VALUES ('a3000000-0000-4000-8000-000000000002','b3000000-0000-4000-8000-000000000002',
    'f3000000-0000-4000-8000-000000000002','d3000000-0000-4000-8000-000000000001',100,'RESERVED','2026-09-18 10:00:00',1);
UPDATE recycler_capacity_pools SET reserved_kg=200,version=3,updated_at='2026-09-18 10:00:00'
WHERE id='d3000000-0000-4000-8000-000000000001';
UPDATE ewaste_batches SET status='APPROVED',version=4,current_claim_id='f3000000-0000-4000-8000-000000000002',updated_at='2026-09-18 10:00:00'
WHERE id='b3000000-0000-4000-8000-000000000002';

INSERT INTO batch_assignments
    (id,batch_id,claim_id,recycler_org_id,collector_org_id,collector_user_id,collector_scope_id,
     assignment_sequence,claim_epoch,assignment_status,assigned_at,responded_at,closed_at,closure_reason,
     version,created_at,updated_at)
VALUES
    ('a4000000-0000-4000-8000-000000000001','b3000000-0000-4000-8000-000000000001',
     'f3000000-0000-4000-8000-000000000001','PROC-001','COL-001','USR-005',
     '54000000-0000-4000-8000-000000000001',1,1,'COMPLETED',
     '2026-09-19 09:00:00','2026-09-19 09:00:00','2026-09-19 10:00:00','COLLECTED',2,
     '2026-09-19 09:00:00','2026-09-19 10:00:00'),
    ('a4000000-0000-4000-8000-000000000002','b3000000-0000-4000-8000-000000000002',
     'f3000000-0000-4000-8000-000000000002','PROC-001','COL-001','USR-005',
     '54000000-0000-4000-8000-000000000001',1,1,'ACCEPTED',
     '2026-09-19 09:00:00','2026-09-19 09:00:00',NULL,NULL,1,
     '2026-09-19 09:00:00','2026-09-19 09:00:00');
UPDATE ewaste_batches SET status='COLLECTED',version=6,current_assignment_id='a4000000-0000-4000-8000-000000000001',updated_at='2026-09-19 10:00:00'
WHERE id='b3000000-0000-4000-8000-000000000001';
UPDATE ewaste_batches SET status='ASSIGNED',version=5,current_assignment_id='a4000000-0000-4000-8000-000000000002',updated_at='2026-09-19 09:00:00'
WHERE id='b3000000-0000-4000-8000-000000000002';

INSERT INTO command_idempotency
    (id,actor_user_id,actor_scope,command_name,idempotency_key,request_hash,batch_id,assignment_id,
     state,response_status,response_json,created_at,completed_at,retain_until)
VALUES ('c4000000-0000-4000-8000-000000000001','USR-005','user:USR-005','RecordCollectionHandoff',
    'C4-Schema-Handoff-0001',SHA2('C4 row constraints',256),'b3000000-0000-4000-8000-000000000001',
    'a4000000-0000-4000-8000-000000000001','COMPLETED',200,JSON_OBJECT('batch_status','COLLECTED'),
    '2026-09-19 10:00:00','2026-09-19 10:00:00','2027-09-19 10:00:00');

INSERT INTO batch_handoffs
    (id,batch_id,assignment_id,collector_user_id,collector_org_id,pickup_status,donor_representative_name,
     actual_item_count,verification_hash,pickup_occurred_at,recorded_at,collected_at,command_id,correlation_id,created_at)
VALUES ('64000000-0000-4000-8000-000000000001','b3000000-0000-4000-8000-000000000001',
    'a4000000-0000-4000-8000-000000000001','USR-005','COL-001','COLLECTED','Synthetic Representative',
    5,REPEAT('a',64),'2026-09-19 10:00:00','2026-09-19 10:00:00','2026-09-19 10:00:00',
    'c4000000-0000-4000-8000-000000000001','c4-schema-fixture','2026-09-19 10:00:00');

INSERT INTO assignment_actions
    (id,batch_id,assignment_id,action_type,actor_user_id,from_status,to_status,assignment_version,
     command_id,occurred_at,correlation_id,details_json)
VALUES ('d4000000-0000-4000-8000-000000000001','b3000000-0000-4000-8000-000000000001',
    'a4000000-0000-4000-8000-000000000001','HANDOFF_RECORDED','USR-005','ASSIGNED','COLLECTED',2,
    'c4000000-0000-4000-8000-000000000001','2026-09-19 10:00:00','c4-schema-fixture',
    JSON_OBJECT('handoff_id','64000000-0000-4000-8000-000000000001','scope_version','1'));
INSERT INTO batch_audit_events
    (id,batch_id,command_id,assignment_id,claim_id,actor_user_id,actor_org_id,event_type,from_status,to_status,
     batch_version,sequence_in_command,occurred_at,correlation_id,details_json)
VALUES ('e4000000-0000-4000-8000-000000000001','b3000000-0000-4000-8000-000000000001',
    'c4000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000001',
    'f3000000-0000-4000-8000-000000000001','USR-005','COL-001','CollectionCompleted','ASSIGNED','COLLECTED',
    6,1,'2026-09-19 10:00:00','c4-schema-fixture',JSON_OBJECT('fixture','row-constraints'));
COMMIT;
PERSISTENCE_EMBED_009

  mkdir -p "$WORK_DIR/database/tests/c4"
  # Embedded database/tests/c4/verify-schema.sql
  cat > "$WORK_DIR/database/tests/c4/verify-schema.sql" <<'PERSISTENCE_EMBED_010'
-- C4 runtime checks. Run only in the runner's disposable MySQL database.
-- All mutation checks roll back; load schema-fixtures.sql first.
-- Expected errors include the exact MySQL error number and named constraint.
SET NAMES utf8mb4;
SET time_zone = '+00:00';
SET SESSION group_concat_max_len = 16384;
CREATE TEMPORARY TABLE c4_results (
    sequence_id INT AUTO_INCREMENT PRIMARY KEY,
    test_name VARCHAR(128) NOT NULL UNIQUE,
    result VARCHAR(4) NOT NULL,
    actual VARCHAR(4096),
    expected VARCHAR(4096)
) ENGINE=MEMORY;
DELIMITER $$
CREATE PROCEDURE c4_assert(IN p_name VARCHAR(128), IN p_actual TEXT, IN p_expected TEXT)
BEGIN
    INSERT INTO c4_results(test_name, result, actual, expected)
    VALUES(p_name, IF(BINARY p_actual <=> BINARY p_expected, 'PASS', 'FAIL'), p_actual, p_expected);
END$$
CREATE PROCEDURE c4_statement(
    IN p_name VARCHAR(128), IN p_sql LONGTEXT,
    IN p_errno INT, IN p_constraint VARCHAR(128))
BEGIN
    DECLARE observed INT DEFAULT 0;
    DECLARE message_text_value TEXT DEFAULT '';
    DECLARE affected INT DEFAULT 0;
    DECLARE prepared_ok BOOLEAN DEFAULT FALSE;
    START TRANSACTION;
    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
            GET DIAGNOSTICS CONDITION 1 observed = MYSQL_ERRNO, message_text_value = MESSAGE_TEXT;
        SET @c4_statement = p_sql;
        PREPARE c4_prepared FROM @c4_statement;
        SET prepared_ok = TRUE;
        EXECUTE c4_prepared;
        SET affected = ROW_COUNT();
    END;
    IF prepared_ok THEN DEALLOCATE PREPARE c4_prepared; END IF;
    ROLLBACK;
    INSERT INTO c4_results(test_name, result, actual, expected)
    VALUES(p_name,
        IF(observed = p_errno
           AND (p_errno <> 0 OR affected = 1)
           AND (p_constraint = '' OR LOCATE(p_constraint, message_text_value) > 0), 'PASS', 'FAIL'),
        IF(observed = 0, CONCAT('accepted rows=', affected), CONCAT(observed, ': ', message_text_value)),
        IF(p_errno = 0, 'accepted rows=1', CONCAT(p_errno, ': ', p_constraint)));
END$$
CREATE PROCEDURE c4_clone(
    IN p_name VARCHAR(128), IN p_table VARCHAR(64), IN p_source VARCHAR(36),
    IN p_id VARCHAR(36), IN p_patch JSON, IN p_errno INT, IN p_constraint VARCHAR(128))
BEGIN
    DECLARE columns_sql TEXT;
    DECLARE values_sql TEXT;
    DECLARE pk_name VARCHAR(16);
    IF p_table NOT IN ('recycler_collector_scopes','batch_assignments','batch_handoffs','assignment_actions','ewaste_batches','command_idempotency','batch_audit_events') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid test table';
    END IF;
    SET pk_name = IF(p_table = 'event_outbox', 'event_id', 'id');
    SELECT GROUP_CONCAT(CONCAT('`', COLUMN_NAME, '`') ORDER BY ORDINAL_POSITION),
           GROUP_CONCAT(CASE
               WHEN JSON_CONTAINS_PATH(p_patch, 'one', CONCAT('$.', COLUMN_NAME))
                   THEN JSON_UNQUOTE(JSON_EXTRACT(p_patch, CONCAT('$.', COLUMN_NAME)))
               WHEN COLUMN_NAME = pk_name THEN QUOTE(p_id)
               ELSE CONCAT('b.`', COLUMN_NAME, '`') END ORDER BY ORDINAL_POSITION)
    INTO columns_sql, values_sql
    FROM information_schema.columns WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table AND GENERATION_EXPRESSION = '';
    CALL c4_statement(p_name,
        CONCAT('INSERT INTO ', p_table, ' (', columns_sql, ') SELECT ', values_sql,
               ' FROM ', p_table, ' b WHERE b.', pk_name, ' = ', QUOTE(p_source)),
        p_errno, p_constraint);
END$$
CREATE PROCEDURE c4_finish()
BEGIN
    IF EXISTS(SELECT 1 FROM c4_results WHERE result <> 'PASS') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'C4 persistence check failed';
    END IF;
END$$
DELIMITER ;





CALL c4_assert('schema.recycler_collector_scopes.columns', CAST((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='recycler_collector_scopes') AS CHAR), '10');

CALL c4_assert('schema.recycler_collector_scopes.engine', CAST((SELECT CONCAT(engine,'/',table_collation) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='recycler_collector_scopes') AS CHAR), 'InnoDB/utf8mb4_0900_ai_ci');

CALL c4_assert('schema.batch_assignments.columns', CAST((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='batch_assignments') AS CHAR), '21');

CALL c4_assert('schema.batch_assignments.engine', CAST((SELECT CONCAT(engine,'/',table_collation) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='batch_assignments') AS CHAR), 'InnoDB/utf8mb4_0900_ai_ci');

CALL c4_assert('schema.batch_handoffs.columns', CAST((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='batch_handoffs') AS CHAR), '18');

CALL c4_assert('schema.batch_handoffs.engine', CAST((SELECT CONCAT(engine,'/',table_collation) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='batch_handoffs') AS CHAR), 'InnoDB/utf8mb4_0900_ai_ci');

CALL c4_assert('schema.assignment_actions.columns', CAST((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='assignment_actions') AS CHAR), '15');

CALL c4_assert('schema.assignment_actions.engine', CAST((SELECT CONCAT(engine,'/',table_collation) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='assignment_actions') AS CHAR), 'InnoDB/utf8mb4_0900_ai_ci');

CALL c4_assert('schema.generated_active_slot', CAST((SELECT CONCAT(extra,'/',is_nullable) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='batch_assignments' AND column_name='active_batch_id') AS CHAR), 'STORED GENERATED/YES');

CALL c4_assert('fixture.closed_slot_null', CAST((SELECT active_batch_id IS NULL FROM batch_assignments WHERE id='a4000000-0000-4000-8000-000000000001') AS CHAR), '1');

CALL c4_assert('fixture.open_slot_batch', CAST((SELECT active_batch_id FROM batch_assignments WHERE id='a4000000-0000-4000-8000-000000000002') AS CHAR), 'b3000000-0000-4000-8000-000000000002');

CALL c4_assert('schema.c3_claim_guards_retained', CAST((SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_schema=DATABASE() AND constraint_name IN ('fk_batches_current_claim','ck_batches_claim_state','fk_batch_audit_claim_batch')) AS CHAR), '3');

CALL c4_assert('schema.assignment_staging_replaced', CAST((SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_schema=DATABASE() AND constraint_name IN ('ck_batches_c1_assignment_null','ck_command_c1_assignment_null','ck_batch_audit_c1_assignment_null')) AS CHAR), '0');

CALL c4_assert('unique.uq_assignment_open', CAST((SELECT CONCAT(MIN(non_unique),':',GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='batch_assignments' AND index_name='uq_assignment_open') AS CHAR), '0:active_batch_id');

CALL c4_assert('unique.uq_assignment_sequence', CAST((SELECT CONCAT(MIN(non_unique),':',GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='batch_assignments' AND index_name='uq_assignment_sequence') AS CHAR), '0:batch_id,assignment_sequence');

CALL c4_assert('unique.uq_assignment_current_tuple', CAST((SELECT CONCAT(MIN(non_unique),':',GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='batch_assignments' AND index_name='uq_assignment_current_tuple') AS CHAR), '0:id,batch_id,claim_id,claim_epoch');

CALL c4_assert('unique.uq_assignment_actor_tuple', CAST((SELECT CONCAT(MIN(non_unique),':',GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='batch_assignments' AND index_name='uq_assignment_actor_tuple') AS CHAR), '0:id,batch_id,collector_user_id,collector_org_id');

CALL c4_assert('unique.uq_handoff_assignment', CAST((SELECT CONCAT(MIN(non_unique),':',GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='batch_handoffs' AND index_name='uq_handoff_assignment') AS CHAR), '0:assignment_id');

CALL c4_assert('unique.uq_handoff_command', CAST((SELECT CONCAT(MIN(non_unique),':',GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='batch_handoffs' AND index_name='uq_handoff_command') AS CHAR), '0:command_id');

CALL c4_assert('unique.uq_assignment_action_command', CAST((SELECT CONCAT(MIN(non_unique),':',GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='assignment_actions' AND index_name='uq_assignment_action_command') AS CHAR), '0:command_id,assignment_id,action_type');

CALL c4_assert('unique.uq_collector_scope_pair_zone', CAST((SELECT CONCAT(MIN(non_unique),':',GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='recycler_collector_scopes' AND index_name='uq_collector_scope_pair_zone') AS CHAR), '0:recycler_org_id,collector_org_id,zone');

CALL c4_assert('fk.fk_batches_current_assignment', CAST((SELECT GROUP_CONCAT(CONCAT(column_name,'>',referenced_column_name) ORDER BY ordinal_position) FROM information_schema.key_column_usage WHERE constraint_schema=DATABASE() AND constraint_name='fk_batches_current_assignment') AS CHAR), 'current_assignment_id>id,id>batch_id,current_claim_id>claim_id,claim_epoch>claim_epoch');

CALL c4_assert('fk.fk_assignment_claim_epoch', CAST((SELECT GROUP_CONCAT(CONCAT(column_name,'>',referenced_column_name) ORDER BY ordinal_position) FROM information_schema.key_column_usage WHERE constraint_schema=DATABASE() AND constraint_name='fk_assignment_claim_epoch') AS CHAR), 'claim_id>id,batch_id>batch_id,claim_epoch>claim_epoch');

CALL c4_assert('fk.fk_assignment_scope_pair', CAST((SELECT GROUP_CONCAT(CONCAT(column_name,'>',referenced_column_name) ORDER BY ordinal_position) FROM information_schema.key_column_usage WHERE constraint_schema=DATABASE() AND constraint_name='fk_assignment_scope_pair') AS CHAR), 'collector_scope_id>id,recycler_org_id>recycler_org_id,collector_org_id>collector_org_id');

CALL c4_assert('fk.fk_handoff_assignment_actor', CAST((SELECT GROUP_CONCAT(CONCAT(column_name,'>',referenced_column_name) ORDER BY ordinal_position) FROM information_schema.key_column_usage WHERE constraint_schema=DATABASE() AND constraint_name='fk_handoff_assignment_actor') AS CHAR), 'assignment_id>id,batch_id>batch_id,collector_user_id>collector_user_id,collector_org_id>collector_org_id');

CALL c4_assert('fk.fk_command_assignment_batch', CAST((SELECT GROUP_CONCAT(CONCAT(column_name,'>',referenced_column_name) ORDER BY ordinal_position) FROM information_schema.key_column_usage WHERE constraint_schema=DATABASE() AND constraint_name='fk_command_assignment_batch') AS CHAR), 'assignment_id>id,batch_id>batch_id');

CALL c4_assert('fk.fk_batch_audit_assignment_batch', CAST((SELECT GROUP_CONCAT(CONCAT(column_name,'>',referenced_column_name) ORDER BY ordinal_position) FROM information_schema.key_column_usage WHERE constraint_schema=DATABASE() AND constraint_name='fk_batch_audit_assignment_batch') AS CHAR), 'assignment_id>id,batch_id>batch_id');

CALL c4_assert('schema.restrictive_c4_foreign_keys', CAST((SELECT COUNT(*) FROM information_schema.referential_constraints WHERE constraint_schema=DATABASE() AND (table_name IN ('recycler_collector_scopes','batch_assignments','batch_handoffs','assignment_actions') OR constraint_name IN ('fk_batches_current_assignment','fk_command_assignment_batch','fk_batch_audit_assignment_batch')) AND delete_rule IN ('RESTRICT','NO ACTION') AND update_rule IN ('RESTRICT','NO ACTION')) AS CHAR), '18');

CALL c4_statement('scope.invalid_zone', 'UPDATE recycler_collector_scopes SET zone=''NORTHEAST'' WHERE id=''54000000-0000-4000-8000-000000000001''', 3819, 'ck_collector_scope_zone');

CALL c4_statement('scope.invalid_active', 'UPDATE recycler_collector_scopes SET is_active=2 WHERE id=''54000000-0000-4000-8000-000000000001''', 3819, 'ck_collector_scope_active');

CALL c4_statement('scope.zero_version', 'UPDATE recycler_collector_scopes SET version=0 WHERE id=''54000000-0000-4000-8000-000000000001''', 3819, 'ck_collector_scope_version');

CALL c4_statement('scope.empty_interval', 'UPDATE recycler_collector_scopes SET valid_until=valid_from WHERE id=''54000000-0000-4000-8000-000000000001''', 3819, 'ck_collector_scope_interval');

CALL c4_statement('scope.time_reversal', 'UPDATE recycler_collector_scopes SET updated_at=created_at-INTERVAL 1 SECOND WHERE id=''54000000-0000-4000-8000-000000000001''', 3819, 'ck_collector_scope_updated');

CALL c4_statement('scope.valid_future_interval', 'UPDATE recycler_collector_scopes SET valid_until=''2026-12-01'' WHERE id=''54000000-0000-4000-8000-000000000001''', 0, '');

CALL c4_clone('scope.unique_pair_zone','recycler_collector_scopes','54000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT(),1062,'uq_collector_scope_pair_zone');

CALL c4_clone('scope.orphan_recycler','recycler_collector_scopes','54000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('recycler_org_id','''missing-recycler'''),1452,'fk_collector_scope_recycler');

CALL c4_clone('scope.orphan_collector','recycler_collector_scopes','54000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('collector_org_id','''missing-collector'''),1452,'fk_collector_scope_collector');

CALL c4_clone('assignment.closed_history_successor','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor'''),0,'');

CALL c4_clone('assignment.duplicate_sequence','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT(),1062,'uq_assignment_sequence');

CALL c4_clone('assignment.one_open_slot','batch_assignments','a4000000-0000-4000-8000-000000000002','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000002''','reassignment_reason','''Another choice'''),1062,'uq_assignment_open');

CALL c4_clone('assignment.orphan_collector','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','collector_user_id','''missing-user'''),1452,'fk_assignment_collector');

CALL c4_clone('assignment.cross_batch_claim','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','claim_id','''f3000000-0000-4000-8000-000000000002'''),1452,'fk_assignment_claim_epoch');

CALL c4_clone('assignment.wrong_claim_epoch','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','claim_epoch','2'),1452,'fk_assignment_claim_epoch');

CALL c4_clone('assignment.wrong_scope_pair','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','collector_org_id','''COL-002'''),1452,'fk_assignment_scope_pair');

CALL c4_clone('assignment.wrong_predecessor_batch','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000002''','reassignment_reason','''Schema successor'''),1452,'fk_assignment_previous_batch');

CALL c4_clone('assignment.self_predecessor','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''94000000-0000-4000-8000-000000000099''','reassignment_reason','''Schema successor'''),3819,'ck_assignment_predecessor');

CALL c4_clone('assignment.no_reassignment_reason','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','NULL'),3819,'ck_assignment_predecessor');

CALL c4_clone('assignment.blank_reassignment_reason','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''   '''),3819,'ck_assignment_predecessor');

CALL c4_clone('assignment.zero_version','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','version','0'),3819,'ck_assignment_version');

CALL c4_clone('assignment.terminal_requires_close','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','closed_at','NULL'),3819,'ck_assignment_closure');

CALL c4_clone('assignment.terminal_requires_reason','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','closure_reason','NULL'),3819,'ck_assignment_closure');

CALL c4_clone('assignment.blank_closure_reason','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','closure_reason',''' '''),3819,'ck_assignment_closure');

CALL c4_clone('assignment.closed_before_assigned','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','closed_at','''2026-09-19 08:00:00''','responded_at','NULL'),3819,'ck_assignment_closure');

CALL c4_clone('assignment.responded_after_closed','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','responded_at','''2026-09-19 10:00:00.000001''','updated_at','''2026-09-19 11:00:00'''),3819,'ck_assignment_response_before_close');

CALL c4_clone('assignment.blank_rejection_reason','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','rejection_reason',''' '''),3819,'ck_assignment_rejection_reason');

CALL c4_clone('assignment.legacy_null_acceptance','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','responded_at','NULL'),0,'');

CALL c4_clone('assignment.accepted_requires_response','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','assignment_status','''ACCEPTED''','responded_at','NULL','closed_at','NULL','closure_reason','NULL'),3819,'ck_assignment_response');

CALL c4_clone('assignment.pending_forbids_response','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','assignment_status','''PENDING''','closed_at','NULL','closure_reason','NULL'),3819,'ck_assignment_response');

CALL c4_clone('assignment.valid_pending','batch_assignments','a4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_sequence','2','previous_assignment_id','''a4000000-0000-4000-8000-000000000001''','reassignment_reason','''Schema successor''','assignment_status','''PENDING''','responded_at','NULL','closed_at','NULL','closure_reason','NULL'),0,'');

CALL c4_statement('assignment.generated_not_input', 'UPDATE batch_assignments SET active_batch_id=''b3000000-0000-4000-8000-000000000001'' WHERE id=''a4000000-0000-4000-8000-000000000001''', 3105, 'active_batch_id');

CALL c4_statement('handoff.success_requires_name', 'UPDATE batch_handoffs SET donor_representative_name=NULL WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_outcome');

CALL c4_statement('handoff.blank_name', 'UPDATE batch_handoffs SET donor_representative_name='' '' WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_donor_name');

CALL c4_statement('handoff.success_requires_count', 'UPDATE batch_handoffs SET actual_item_count=NULL WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_outcome');

CALL c4_statement('handoff.count_zero', 'UPDATE batch_handoffs SET actual_item_count=0 WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_count');

CALL c4_statement('handoff.count_overflow', 'UPDATE batch_handoffs SET actual_item_count=100001 WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_count');

CALL c4_statement('handoff.count_max', 'UPDATE batch_handoffs SET actual_item_count=100000 WHERE id=''64000000-0000-4000-8000-000000000001''', 0, '');

CALL c4_statement('handoff.success_requires_hash', 'UPDATE batch_handoffs SET verification_hash=NULL WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_outcome');

CALL c4_statement('handoff.hash_short', 'UPDATE batch_handoffs SET verification_hash=REPEAT(''a'',63) WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_hash');

CALL c4_statement('handoff.hash_nonhex', 'UPDATE batch_handoffs SET verification_hash=REPEAT(''z'',64) WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_hash');

CALL c4_statement('handoff.hash_uppercase', 'UPDATE batch_handoffs SET verification_hash=REPEAT(''A'',64) WHERE id=''64000000-0000-4000-8000-000000000001''', 0, '');

CALL c4_statement('handoff.success_requires_collected', 'UPDATE batch_handoffs SET collected_at=NULL WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_outcome');

CALL c4_statement('handoff.collected_equals_pickup', 'UPDATE batch_handoffs SET collected_at=pickup_occurred_at-INTERVAL 1 MICROSECOND WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_outcome');

CALL c4_statement('handoff.future_pickup', 'UPDATE batch_handoffs SET pickup_occurred_at=recorded_at+INTERVAL 1 MICROSECOND,collected_at=recorded_at+INTERVAL 1 MICROSECOND WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_times');

CALL c4_statement('handoff.recorded_after_created', 'UPDATE batch_handoffs SET recorded_at=created_at+INTERVAL 1 MICROSECOND WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_times');

CALL c4_statement('handoff.failure_requires_reason', 'UPDATE batch_handoffs SET pickup_status=''FAILED_COLLECTION'',collected_at=NULL WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_outcome');

CALL c4_statement('handoff.failure_invalid_reason', 'UPDATE batch_handoffs SET pickup_status=''FAILED_COLLECTION'',collected_at=NULL,failure_reason=''OTHER'' WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_outcome');

CALL c4_statement('handoff.failure_without_fabricated_evidence', 'UPDATE batch_handoffs SET pickup_status=''FAILED_COLLECTION'',collected_at=NULL,failure_reason=''DONOR_UNAVAILABLE'',donor_representative_name=NULL,actual_item_count=NULL,verification_hash=NULL WHERE id=''64000000-0000-4000-8000-000000000001''', 0, '');

CALL c4_statement('handoff.failure_observed_count_optional', 'UPDATE batch_handoffs SET pickup_status=''FAILED_COLLECTION'',collected_at=NULL,failure_reason=''INCORRECT_ITEMS'',actual_item_count=7 WHERE id=''64000000-0000-4000-8000-000000000001''', 0, '');

CALL c4_statement('handoff.optional_discrepancy', 'UPDATE batch_handoffs SET actual_item_count=7,quantity_discrepancy_reason=NULL WHERE id=''64000000-0000-4000-8000-000000000001''', 0, '');

CALL c4_statement('handoff.blank_discrepancy', 'UPDATE batch_handoffs SET quantity_discrepancy_reason='' '' WHERE id=''64000000-0000-4000-8000-000000000001''', 3819, 'ck_handoff_discrepancy');

CALL c4_statement('handoff.wrong_collector', 'UPDATE batch_handoffs SET collector_user_id=''USR-006'' WHERE id=''64000000-0000-4000-8000-000000000001''', 1452, 'fk_handoff_assignment_actor');

CALL c4_statement('handoff.wrong_collector_org', 'UPDATE batch_handoffs SET collector_org_id=''COL-002'' WHERE id=''64000000-0000-4000-8000-000000000001''', 1452, 'fk_handoff_assignment_actor');

CALL c4_statement('handoff.wrong_batch', 'UPDATE batch_handoffs SET batch_id=''b3000000-0000-4000-8000-000000000002'' WHERE id=''64000000-0000-4000-8000-000000000001''', 1452, 'fk_handoff_assignment_actor');

CALL c4_statement('handoff.orphan_command', 'UPDATE batch_handoffs SET command_id=''missing-command'' WHERE id=''64000000-0000-4000-8000-000000000001''', 1452, 'fk_handoff_command');

CALL c4_clone('handoff.one_outcome_per_assignment','batch_handoffs','64000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('command_id','''c3000000-0000-4000-8000-000000000001'''),1062,'uq_handoff_assignment');

CALL c4_clone('handoff.one_outcome_per_command','batch_handoffs','64000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT('assignment_id','''a4000000-0000-4000-8000-000000000002''','batch_id','''b3000000-0000-4000-8000-000000000002'''),1062,'uq_handoff_command');

CALL c4_clone('action.unique_command_type','assignment_actions','d4000000-0000-4000-8000-000000000001','94000000-0000-4000-8000-000000000099',JSON_OBJECT(),1062,'uq_assignment_action_command');

CALL c4_statement('action.wrong_type', 'UPDATE assignment_actions SET action_type=''RECOVERED'' WHERE id=''d4000000-0000-4000-8000-000000000001''', 3819, 'ck_assignment_action_type');

CALL c4_statement('action.no_actor', 'UPDATE assignment_actions SET actor_user_id=NULL WHERE id=''d4000000-0000-4000-8000-000000000001''', 3819, 'ck_assignment_action_actor');

CALL c4_statement('action.two_actors', 'UPDATE assignment_actions SET service_principal=''recovery-service'' WHERE id=''d4000000-0000-4000-8000-000000000001''', 3819, 'ck_assignment_action_actor');

CALL c4_statement('action.service_actor', 'UPDATE assignment_actions SET actor_user_id=NULL,service_principal=''fixture-service'' WHERE id=''d4000000-0000-4000-8000-000000000001''', 0, '');

CALL c4_statement('action.rejection_needs_reason', 'UPDATE assignment_actions SET action_type=''REJECTED'' WHERE id=''d4000000-0000-4000-8000-000000000001''', 3819, 'ck_assignment_action_reason');

CALL c4_statement('action.reassignment_needs_previous', 'UPDATE assignment_actions SET action_type=''REASSIGNED'',reason=''fixture reason'' WHERE id=''d4000000-0000-4000-8000-000000000001''', 3819, 'ck_assignment_action_previous');

CALL c4_statement('action.wrong_predecessor_batch', 'UPDATE assignment_actions SET previous_assignment_id=''a4000000-0000-4000-8000-000000000002'' WHERE id=''d4000000-0000-4000-8000-000000000001''', 1452, 'fk_assignment_action_previous');

CALL c4_statement('action.wrong_assignment_batch', 'UPDATE assignment_actions SET assignment_id=''a4000000-0000-4000-8000-000000000002'' WHERE id=''d4000000-0000-4000-8000-000000000001''', 1452, 'fk_assignment_action_attempt');

CALL c4_statement('action.version_zero', 'UPDATE assignment_actions SET assignment_version=0 WHERE id=''d4000000-0000-4000-8000-000000000001''', 3819, 'ck_assignment_action_version');

CALL c4_statement('pointer.cross_batch', 'UPDATE ewaste_batches SET current_assignment_id=''a4000000-0000-4000-8000-000000000002'' WHERE id=''b3000000-0000-4000-8000-000000000001''', 1452, 'fk_batches_current_assignment');

CALL c4_statement('pointer.custody_requires_assignment', 'UPDATE ewaste_batches SET current_assignment_id=NULL WHERE id=''b3000000-0000-4000-8000-000000000001''', 3819, 'ck_batches_assignment_state');

CALL c4_statement('pointer.approved_forbids_assignment', 'UPDATE ewaste_batches SET status=''APPROVED'' WHERE id=''b3000000-0000-4000-8000-000000000001''', 3819, 'ck_batches_assignment_state');

CALL c4_statement('command.cross_batch', 'UPDATE command_idempotency SET batch_id=''b3000000-0000-4000-8000-000000000002'' WHERE id=''c4000000-0000-4000-8000-000000000001''', 1452, 'fk_command_assignment_batch');

CALL c4_statement('command.null_pair_bypass', 'UPDATE command_idempotency SET batch_id=NULL WHERE id=''c4000000-0000-4000-8000-000000000001''', 3819, 'ck_command_assignment_batch');

CALL c4_statement('audit.cross_batch', 'UPDATE batch_audit_events SET assignment_id=''a4000000-0000-4000-8000-000000000002'' WHERE id=''e4000000-0000-4000-8000-000000000001''', 1452, 'fk_batch_audit_assignment_batch');

CALL c4_statement('history.restrict_assignment', 'DELETE FROM batch_assignments WHERE id=''a4000000-0000-4000-8000-000000000001''', 1451, '');

CALL c4_statement('history.restrict_scope', 'DELETE FROM recycler_collector_scopes WHERE id=''54000000-0000-4000-8000-000000000001''', 1451, 'fk_assignment_scope_pair');

SELECT test_name,result,actual,expected FROM c4_results ORDER BY sequence_id;

CALL c4_finish();

DROP PROCEDURE c4_clone;

DROP PROCEDURE c4_statement;

DROP PROCEDURE c4_assert;

DROP PROCEDURE c4_finish;

DROP TEMPORARY TABLE c4_results;
PERSISTENCE_EMBED_010

  mkdir -p "$WORK_DIR/database/seed"
  # Embedded database/seed/104-seed-c1-batches.sql
  cat > "$WORK_DIR/database/seed/104-seed-c1-batches.sql" <<'PERSISTENCE_EMBED_011'
--liquibase formatted sql

--changeset team5:EWCSB126-104 dbms:mysql context:@c1-fixtures labels:synthetic-test-data
--preconditions onFail:HALT onError:HALT
--precondition-sql-check expectedResult:2 SELECT COUNT(*) FROM users WHERE (user_id = 'USR-003' AND organisation_id = 'DON-001' AND role_code = 'DONOR' AND status = 'ACTIVE') OR (user_id = 'USR-004' AND organisation_id = 'DON-002' AND role_code = 'DONOR' AND status = 'ACTIVE');
--comment: Explicit opt-in C1 fixtures. Use context-filter=seed,c1-fixtures on isolated test databases.
-- Fixed UUIDv4 values and UTC dates; no NOW(), random IDs, UPSERT or history deletion.
-- Liquibase runs this transaction once; a second update is a no-op.
SET time_zone = '+00:00';

INSERT INTO ewaste_batches (
    id, organization_id, created_by, status, category, quantity,
    estimated_weight_kg, condition_rating, is_data_bearing, zone,
    collection_deadline, notes, claim_epoch, current_claim_id,
    current_assignment_id, version, submitted_at, created_at, updated_at
) VALUES
('b1260000-0000-4000-8000-000000000001', 'DON-001', 'USR-003', 'DRAFT',
 NULL, NULL, NULL, NULL, FALSE, NULL, NULL, NULL,
 1, NULL, NULL, 1, NULL, '2026-09-01 00:00:00.000000', '2026-09-01 00:00:00.000000'),
('b1260000-0000-4000-8000-000000000002', 'DON-002', 'USR-004', 'DRAFT',
 'BATTERIES', 1, NULL, NULL, TRUE, 'WEST', NULL, 'Partial synthetic draft',
 1, NULL, NULL, 1, NULL, '2026-09-01 00:00:00.000000', '2026-09-01 00:00:00.000000'),
('b1260000-0000-4000-8000-000000000003', 'DON-001', 'USR-003', 'SUBMITTED',
 'ICT_EQUIPMENT', 1, 0.10, 'FUNCTIONAL', FALSE, 'NORTH', '2026-09-03 01:00:00.000000', NULL,
 1, NULL, NULL, 2, '2026-09-01 01:00:00.000000', '2026-09-01 00:00:00.000000', '2026-09-01 01:00:00.000000'),
('b1260000-0000-4000-8000-000000000004', 'DON-002', 'USR-004', 'SUBMITTED',
 'LARGE_APPLIANCE', 100000, 50000.00, 'END_OF_LIFE', TRUE, 'SOUTH', '2026-11-30 01:00:00.000000', REPEAT('界', 500),
 1, NULL, NULL, 2, '2026-09-01 01:00:00.000000', '2026-09-01 00:00:00.000000', '2026-09-01 01:00:00.000000'),
('b1260000-0000-4000-8000-000000000005', 'DON-001', 'USR-003', 'SUBMITTED',
 'BATTERIES', 10, 12.34, 'REPAIRABLE', TRUE, 'EAST', '2026-09-04 01:00:00.000000', '',
 1, NULL, NULL, 2, '2026-09-01 01:00:00.000000', '2026-09-01 00:00:00.000000', '2026-09-01 01:00:00.000000'),
('b1260000-0000-4000-8000-000000000006', 'DON-002', 'USR-004', 'SUBMITTED',
 'CONSUMER_ELECTRONICS', 25, 250.50, 'FUNCTIONAL', FALSE, 'WEST', '2026-09-05 01:00:00.000000', 'Synthetic electronics',
 1, NULL, NULL, 2, '2026-09-01 01:00:00.000000', '2026-09-01 00:00:00.000000', '2026-09-01 01:00:00.000000'),
('b1260000-0000-4000-8000-000000000007', 'DON-001', 'USR-003', 'SUBMITTED',
 'ICT_EQUIPMENT', 5, 100.00, 'REPAIRABLE', TRUE, 'CENTRAL', '2026-09-08 01:00:00.000000', 'Synthetic ICT',
 1, NULL, NULL, 2, '2026-09-01 01:00:00.000000', '2026-09-01 00:00:00.000000', '2026-09-01 01:00:00.000000');

-- These command labels and hashes describe fixture history, not a new HTTP contract.
-- retain_until is a fixed test value, not a production retention policy.
INSERT INTO command_idempotency (
    id, actor_user_id, actor_scope, command_name, idempotency_key, request_hash,
    batch_id, state, response_status, response_json, created_at, completed_at, retain_until
)
SELECT CONCAT('c1260000', SUBSTRING(id, 9)), created_by, CONCAT('user:', created_by),
       'CreateDraft', CONCAT('c1-fixture-create:', id), SHA2(CONCAT('c1-fixture-create:', id), 256),
       id, 'COMPLETED', 201,
       JSON_OBJECT('batchId', id, 'status', 'DRAFT', 'version', 1),
       created_at, created_at, '2027-09-01 00:00:00.000000'
FROM ewaste_batches WHERE id IN (
    'b1260000-0000-4000-8000-000000000001',
    'b1260000-0000-4000-8000-000000000002',
    'b1260000-0000-4000-8000-000000000003',
    'b1260000-0000-4000-8000-000000000004',
    'b1260000-0000-4000-8000-000000000005',
    'b1260000-0000-4000-8000-000000000006',
    'b1260000-0000-4000-8000-000000000007');

INSERT INTO batch_audit_events (
    id, batch_id, command_id, actor_user_id, actor_org_id, event_type,
    from_status, to_status, batch_version, sequence_in_command,
    occurred_at, correlation_id, details_json
)
SELECT CONCAT('a1260000', SUBSTRING(id, 9)), id, CONCAT('c1260000', SUBSTRING(id, 9)),
       created_by, organization_id, 'DraftSaved', 'DRAFT', 'DRAFT', 1, 1,
       created_at, CONCAT('c1-fixture-create:', id), JSON_OBJECT('operation', 'CREATE')
FROM ewaste_batches WHERE id IN (
    'b1260000-0000-4000-8000-000000000001',
    'b1260000-0000-4000-8000-000000000002',
    'b1260000-0000-4000-8000-000000000003',
    'b1260000-0000-4000-8000-000000000004',
    'b1260000-0000-4000-8000-000000000005',
    'b1260000-0000-4000-8000-000000000006',
    'b1260000-0000-4000-8000-000000000007');

INSERT INTO command_idempotency (
    id, actor_user_id, actor_scope, command_name, idempotency_key, request_hash,
    batch_id, state, response_status, response_json, created_at, completed_at, retain_until
)
SELECT CONCAT('c1260001', SUBSTRING(id, 9)), created_by, CONCAT('user:', created_by),
       'SubmitBatch', CONCAT('c1-fixture-submit:', id), SHA2(CONCAT('c1-fixture-submit:', id), 256),
       id, 'COMPLETED', 200,
       JSON_OBJECT('batchId', id, 'status', 'SUBMITTED', 'version', 2,
                   'eventId', CONCAT('e1260000', SUBSTRING(id, 9)), 'eventState', 'PENDING'),
       submitted_at, submitted_at, '2027-09-01 00:00:00.000000'
FROM ewaste_batches WHERE id IN (
    'b1260000-0000-4000-8000-000000000001',
    'b1260000-0000-4000-8000-000000000002',
    'b1260000-0000-4000-8000-000000000003',
    'b1260000-0000-4000-8000-000000000004',
    'b1260000-0000-4000-8000-000000000005',
    'b1260000-0000-4000-8000-000000000006',
    'b1260000-0000-4000-8000-000000000007') AND status = 'SUBMITTED';

INSERT INTO batch_audit_events (
    id, batch_id, command_id, actor_user_id, actor_org_id, event_type,
    from_status, to_status, batch_version, sequence_in_command,
    occurred_at, correlation_id, details_json
)
SELECT CONCAT('a1260001', SUBSTRING(id, 9)), id, CONCAT('c1260001', SUBSTRING(id, 9)),
       created_by, organization_id, 'RequestSubmitted', 'DRAFT', 'SUBMITTED', version, 1,
       submitted_at, CONCAT('c1-fixture-submit:', id), JSON_OBJECT('operation', 'SUBMIT')
FROM ewaste_batches WHERE id IN (
    'b1260000-0000-4000-8000-000000000001',
    'b1260000-0000-4000-8000-000000000002',
    'b1260000-0000-4000-8000-000000000003',
    'b1260000-0000-4000-8000-000000000004',
    'b1260000-0000-4000-8000-000000000005',
    'b1260000-0000-4000-8000-000000000006',
    'b1260000-0000-4000-8000-000000000007') AND status = 'SUBMITTED';

INSERT INTO event_outbox (
    event_id, batch_id, command_id, event_type, topic, schema_version,
    aggregate_version, sequence_in_command, partition_key, payload_json,
    correlation_id, occurred_at, created_at, publish_state, attempt_count, next_attempt_at
)
SELECT CONCAT('e1260000', SUBSTRING(id, 9)), id, CONCAT('c1260001', SUBSTRING(id, 9)),
       'RequestSubmitted', 'ewaste.batch.events', 1, version, 1, id,
       JSON_OBJECT(
           'event_id', CONCAT('e1260000', SUBSTRING(id, 9)), 'event_type', 'RequestSubmitted',
           'schema_version', 1, 'command_id', CONCAT('c1260001', SUBSTRING(id, 9)),
           'batch_id', id, 'batch_version', version, 'claim_epoch', CAST(claim_epoch AS CHAR),
           'sequence_in_command', 1, 'occurred_at', DATE_FORMAT(submitted_at, '%Y-%m-%dT%H:%i:%s.%fZ'),
           'correlation_id', CONCAT('c1-fixture-submit:', id),
           'data', JSON_OBJECT(
               'organization_id', organization_id,
               'submitted_at', DATE_FORMAT(submitted_at, '%Y-%m-%dT%H:%i:%s.%fZ'),
               'category', category, 'quantity', quantity,
               'estimated_weight_kg', CAST(estimated_weight_kg AS CHAR),
               'condition_rating', condition_rating,
               'is_data_bearing', JSON_EXTRACT(IF(is_data_bearing, 'true', 'false'), '$'),
               'zone', zone, 'collection_deadline', DATE_FORMAT(collection_deadline, '%Y-%m-%dT%H:%i:%s.%fZ'))),
       CONCAT('c1-fixture-submit:', id), submitted_at, submitted_at, 'PENDING', 0, submitted_at
FROM ewaste_batches WHERE id IN (
    'b1260000-0000-4000-8000-000000000001',
    'b1260000-0000-4000-8000-000000000002',
    'b1260000-0000-4000-8000-000000000003',
    'b1260000-0000-4000-8000-000000000004',
    'b1260000-0000-4000-8000-000000000005',
    'b1260000-0000-4000-8000-000000000006',
    'b1260000-0000-4000-8000-000000000007') AND status = 'SUBMITTED';

-- No destructive rollback: fixture command/audit/outbox history is retained.
-- The test runner disposes only of its own isolated container volume.
PERSISTENCE_EMBED_011

  mkdir -p "$WORK_DIR/backend/api"
  # Embedded backend/api/embed_test.go
  cat > "$WORK_DIR/backend/api/embed_test.go" <<'PERSISTENCE_EMBED_012'
package api

import (
	"bytes"
	"testing"
)

func TestOpenAPISpecIsEmbedded(t *testing.T) {
	if len(OpenAPISpec) == 0 {
		t.Fatal("expected embedded OpenAPI specification")
	}
	if !bytes.HasPrefix(OpenAPISpec, []byte("openapi: 3.0.3")) {
		t.Fatalf("expected OpenAPI 3.0.3 specification, got %q", OpenAPISpec[:min(len(OpenAPISpec), 30)])
	}
}
PERSISTENCE_EMBED_012

  mkdir -p "$WORK_DIR/backend/cmd/server"
  # Embedded backend/cmd/server/main_test.go
  cat > "$WORK_DIR/backend/cmd/server/main_test.go" <<'PERSISTENCE_EMBED_013'
package main

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"workflow-api/internal/router"
)

func Test_RunTestServer(t *testing.T) {
	r := router.NewTestRouter()

	req := httptest.NewRequest(http.MethodGet, "/api/v1/hello", nil)
	res := httptest.NewRecorder()

	r.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected status %d, got %d", http.StatusOK, res.Code)
	}

	expected := `{"msg":"hello world"}`
	if res.Body.String() != expected {
		t.Fatalf("expected body %s, got %s", expected, res.Body.String())
	}
}
PERSISTENCE_EMBED_013

  mkdir -p "$WORK_DIR/backend/internal/config"
  # Embedded backend/internal/config/config_test.go
  cat > "$WORK_DIR/backend/internal/config/config_test.go" <<'PERSISTENCE_EMBED_014'
package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadReadsConfigFileAndEnvironmentOverrides(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	contents := []byte(`
server:
  port: ":9090"
database:
  host: "mysql"
  port: 3306
  name: "ewaste"
  user: "ewaste_app"
auth:
  access_ttl: "10m"
  refresh_ttl: "2h"
`)
	if err := os.WriteFile(configPath, contents, 0o600); err != nil {
		t.Fatalf("write test config: %v", err)
	}
	t.Setenv("MYSQL_PASSWORD", "db-secret")
	t.Setenv("REDIS_PASSWORD", "redis-secret")
	t.Setenv("EWASTE_MODE", "production")
	t.Setenv("EWASTE_SERVER_PORT", ":8181")
	t.Setenv("EWASTE_DATABASE_HOST", "azure-mysql")
	t.Setenv("EWASTE_DATABASE_PORT", "3306")
	t.Setenv("EWASTE_DATABASE_NAME", "ewastedb")
	t.Setenv("EWASTE_DATABASE_USER", "ewasteadmin")
	t.Setenv("EWASTE_REDIS_ADDRESS", "azure-redis:6380")
	t.Setenv("EWASTE_REDIS_DB", "1")
	t.Setenv("EWASTE_REDIS_TLS_ENABLED", "true")
	t.Setenv("EWASTE_AUTH_ISSUER", "integration-api")
	t.Setenv("EWASTE_AUTH_ACCESS_TTL", "20m")
	t.Setenv("EWASTE_AUTH_REFRESH_TTL", "3h")
	t.Setenv("EWASTE_RATE_LIMIT_REQUESTS", "25")
	t.Setenv("EWASTE_RATE_LIMIT_WINDOW", "2m")

	cfg, err := Load(configPath)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.Server.Port != ":8181" {
		t.Fatalf("expected server port from environment, got %q", cfg.Server.Port)
	}
	if cfg.Mode != ModeProduction || cfg.Database.Host != "azure-mysql" || cfg.Database.Port != 3306 || cfg.Database.Name != "ewastedb" || cfg.Database.User != "ewasteadmin" {
		t.Fatalf("expected database and mode environment values, got mode=%q database=%+v", cfg.Mode, cfg.Database)
	}
	if cfg.Database.Password != "db-secret" || cfg.Redis.Password != "redis-secret" || cfg.Redis.Address != "azure-redis:6380" || cfg.Redis.DB != 1 || !cfg.Redis.TLSEnabled {
		t.Fatalf("expected credential environment values, got database=%q redis=%q", cfg.Database.Password, cfg.Redis.Password)
	}
	if cfg.Auth.Issuer != "integration-api" || cfg.Auth.AccessTTL.Minutes() != 20 || cfg.Auth.RefreshTTL.Hours() != 3 {
		t.Fatalf("expected auth environment values, got issuer=%q access=%s refresh=%s", cfg.Auth.Issuer, cfg.Auth.AccessTTL, cfg.Auth.RefreshTTL)
	}
	if cfg.RateLimit.Requests != 25 || cfg.RateLimit.Window.Minutes() != 2 {
		t.Fatalf("expected rate limit environment values, got requests=%d window=%s", cfg.RateLimit.Requests, cfg.RateLimit.Window)
	}
}

func TestApplyTestModeUsesLocalDependencies(t *testing.T) {
	cfg := Config{Redis: RedisConfig{Address: ""}}
	if err := cfg.ApplyMode(ModeTest); err != nil {
		t.Fatalf("apply test mode: %v", err)
	}
	if cfg.Database.Host != "localhost" || cfg.Database.Port != 3307 || cfg.Redis.Address != "localhost:6379" {
		t.Fatalf("expected localhost dependency defaults: %+v", cfg)
	}
}
PERSISTENCE_EMBED_014

  mkdir -p "$WORK_DIR/backend/internal/controller"
  # Embedded backend/internal/controller/auth_test.go
  cat > "$WORK_DIR/backend/internal/controller/auth_test.go" <<'PERSISTENCE_EMBED_015'
package controller

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"
	"golang.org/x/crypto/bcrypt"

	"workflow-api/internal/dto"
	"workflow-api/internal/middleware"
	"workflow-api/internal/model"
	"workflow-api/internal/repository"
	"workflow-api/internal/service"
	"workflow-api/internal/token"
)

type authRepositoryStub struct {
	user      *model.User
	findErr   error
	session   *model.Session
	audits    []*model.LoginAudit
	createErr error
	rotateErr error
	revokeErr error
}

func (s *authRepositoryStub) FindActiveUserByEmail(context.Context, string) (*model.User, error) {
	if s.findErr != nil {
		return nil, s.findErr
	}
	if s.user == nil {
		return nil, repository.ErrNotFound
	}
	return s.user, nil
}

func (s *authRepositoryStub) FindActiveUserByID(context.Context, string) (*model.User, error) {
	if s.user == nil || s.user.Status != "ACTIVE" {
		return nil, repository.ErrNotFound
	}
	return s.user, nil
}

func (s *authRepositoryStub) CreateLoginSession(_ context.Context, _ *model.User, session *model.Session, _ time.Time) error {
	if s.createErr != nil {
		return s.createErr
	}
	s.session = session
	return nil
}

func (s *authRepositoryStub) CreateLoginAudit(_ context.Context, audit *model.LoginAudit) error {
	s.audits = append(s.audits, audit)
	return nil
}

func (s *authRepositoryStub) FindSession(context.Context, string) (*model.Session, error) {
	if s.session == nil {
		return nil, repository.ErrNotFound
	}
	return s.session, nil
}

func (s *authRepositoryStub) RotateSession(context.Context, string, string, string, string, time.Time, time.Time) error {
	return s.rotateErr
}

func (s *authRepositoryStub) RevokeSession(context.Context, string, string, string, time.Time) error {
	return s.revokeErr
}

func newLoginTestRouter(repo repository.AuthRepository) *gin.Engine {
	gin.SetMode(gin.TestMode)
	logger := zap.NewNop()
	tokens := token.NewService("test", "access-secret", "refresh-secret", "hash-secret", 15*time.Minute, 24*time.Hour)
	authService := service.NewAuthService(repo, tokens, logger)
	authController := NewAuthController(authService, logger)

	r := gin.New()
	r.Use(middleware.CorrelationID())
	r.POST("/api/v1/auth/login", authController.Login)
	return r
}

func activeUserForTest(t *testing.T) *model.User {
	t.Helper()
	hash, err := bcrypt.GenerateFromPassword([]byte("correct-password"), bcrypt.MinCost)
	if err != nil {
		t.Fatalf("hash password: %v", err)
	}
	return &model.User{
		UserID: "USR-001", Email: "user@example.com", PasswordHash: string(hash),
		RoleCode: "DONOR", OrganisationID: "DON-001", Status: "ACTIVE",
	}
}

func TestLoginReturnsFlatTokenResponseAndCorrelationID(t *testing.T) {
	r := newLoginTestRouter(&authRepositoryStub{user: activeUserForTest(t)})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"email":"USER@EXAMPLE.COM","password":"correct-password"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Correlation-ID", "corr-login-001")
	res := httptest.NewRecorder()

	r.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", res.Code, res.Body.String())
	}
	if res.Header().Get("X-Correlation-ID") != "corr-login-001" {
		t.Fatalf("expected correlation ID to be echoed, got %q", res.Header().Get("X-Correlation-ID"))
	}
	var response dto.TokenResponse
	if err := json.Unmarshal(res.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.AccessToken == "" || response.RefreshToken == "" || response.TokenType != "Bearer" {
		t.Fatalf("unexpected token response: %+v", response)
	}
	if response.ExpiresIn != 900 || response.RefreshExpiresIn != 86400 {
		t.Fatalf("unexpected token lifetimes: %+v", response)
	}
}

func TestLoginReturnsSafeBadRequest(t *testing.T) {
	repo := &authRepositoryStub{user: activeUserForTest(t)}
	r := newLoginTestRouter(repo)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"email":"user@example.com"}`))
	req.Header.Set("Content-Type", "application/json")
	res := httptest.NewRecorder()

	r.ServeHTTP(res, req)

	if res.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", res.Code)
	}
	var response dto.ErrorResponse
	if err := json.Unmarshal(res.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if response.Code != "AUTH_INVALID_REQUEST" || response.Message != "invalid request" || response.CorrelationID == "" {
		t.Fatalf("unexpected safe error: %+v", response)
	}
	if len(repo.audits) != 1 || repo.audits[0].Result != service.LoginAuditFailure || repo.audits[0].ReasonCode == nil || *repo.audits[0].ReasonCode != "AUTH_INVALID_REQUEST" {
		t.Fatalf("unexpected invalid-request audit: %+v", repo.audits)
	}
}

func TestLoginReturnsGenericUnauthorizedError(t *testing.T) {
	r := newLoginTestRouter(&authRepositoryStub{})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"email":"unknown@example.com","password":"wrong"}`))
	req.Header.Set("Content-Type", "application/json")
	res := httptest.NewRecorder()

	r.ServeHTTP(res, req)

	if res.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", res.Code)
	}
	if strings.Contains(res.Body.String(), "unknown@example.com") || strings.Contains(res.Body.String(), "wrong") {
		t.Fatalf("response exposed sensitive login input: %s", res.Body.String())
	}
	var response dto.ErrorResponse
	if err := json.Unmarshal(res.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if response.Code != "AUTH_INVALID_CREDENTIALS" || response.Message != "invalid credentials" {
		t.Fatalf("unexpected credentials error: %+v", response)
	}
}

func TestLoginReturns503ForRepositoryFailure(t *testing.T) {
	r := newLoginTestRouter(&authRepositoryStub{findErr: errors.New("database unavailable")})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"email":"user@example.com","password":"password"}`))
	req.Header.Set("Content-Type", "application/json")
	res := httptest.NewRecorder()

	r.ServeHTTP(res, req)

	if res.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", res.Code)
	}
	if strings.Contains(res.Body.String(), "database unavailable") {
		t.Fatalf("response exposed dependency error: %s", res.Body.String())
	}
}
PERSISTENCE_EMBED_015

  mkdir -p "$WORK_DIR/backend/internal/docs"
  # Embedded backend/internal/docs/handler_test.go
  cat > "$WORK_DIR/backend/internal/docs/handler_test.go" <<'PERSISTENCE_EMBED_016'
package docs

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestRegisterServesOpenAPISpec(t *testing.T) {
	r := gin.New()
	Register(r)

	recorder := httptest.NewRecorder()
	r.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/openapi.yaml", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", recorder.Code)
	}
	if !strings.Contains(recorder.Body.String(), "openapi: 3.0.3") {
		t.Fatal("expected embedded OpenAPI specification in response")
	}
}

func TestRegisterServesEmbeddedSwaggerUI(t *testing.T) {
	r := gin.New()
	Register(r)

	recorder := httptest.NewRecorder()
	r.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/docs/", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", recorder.Code)
	}
	if !strings.Contains(strings.ToLower(recorder.Body.String()), "swagger") {
		t.Fatal("expected Swagger UI HTML response")
	}
}
PERSISTENCE_EMBED_016

  mkdir -p "$WORK_DIR/backend/internal/dto"
  # Embedded backend/internal/dto/auth_test.go
  cat > "$WORK_DIR/backend/internal/dto/auth_test.go" <<'PERSISTENCE_EMBED_017'
package dto

import (
	"encoding/json"
	"testing"
)

func TestTokenResponseUsesAPIFieldNames(t *testing.T) {
	payload, err := json.Marshal(TokenResponse{
		AccessToken: "access", RefreshToken: "refresh", TokenType: "Bearer", ExpiresIn: 900, RefreshExpiresIn: 86400,
	})
	if err != nil {
		t.Fatalf("marshal token response: %v", err)
	}
	expected := `{"accessToken":"access","refreshToken":"refresh","tokenType":"Bearer","expiresIn":900,"refreshExpiresIn":86400}`
	if string(payload) != expected {
		t.Fatalf("expected %s, got %s", expected, payload)
	}
}

func TestErrorResponseUsesCorrelationIdField(t *testing.T) {
	payload, err := json.Marshal(ErrorResponse{Code: "AUTH_INVALID_REQUEST", Message: "invalid request", CorrelationID: "corr-001"})
	if err != nil {
		t.Fatalf("marshal error response: %v", err)
	}
	if string(payload) != `{"code":"AUTH_INVALID_REQUEST","message":"invalid request","correlationId":"corr-001"}` {
		t.Fatalf("unexpected error response: %s", payload)
	}
}
PERSISTENCE_EMBED_017

  mkdir -p "$WORK_DIR/backend/internal/events"
  # Embedded backend/internal/events/c4_test.go
  cat > "$WORK_DIR/backend/internal/events/c4_test.go" <<'PERSISTENCE_EMBED_018'
package events

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func TestC4CanonicalEnvelopeKeys(t *testing.T) {
	c := Context{EventID: "e4000000-0000-4000-8000-000000000001", CommandID: "c4000000-0000-4000-8000-000000000001",
		BatchID: "b4000000-0000-4000-8000-000000000001", BatchVersion: 9, ClaimEpoch: "18446744073709551615",
		OccurredAt: time.Date(2026, 9, 19, 12, 0, 0, 123000, time.UTC), CorrelationID: "c4-envelope-test"}
	previous := "a4000000-0000-4000-8000-000000000001"
	cases := []struct {
		data        any
		kind, topic string
	}{
		{CollectorAssignedData{ClaimID: "f4000000-0000-4000-8000-000000000001", AssignmentID: "a4000000-0000-4000-8000-000000000002",
			RecyclerOrgID: "PROC-001", CollectorOrgID: "COL-001", CollectorUserID: "USR-005", CollectorScopeID: "54000000-0000-4000-8000-000000000001",
			AssignedAt: Timestamp(c.OccurredAt), AssignmentSequence: "18446744073709551615", AssignmentVersion: "1", PreviousAssignmentID: &previous}, CollectorAssigned, "batch.collector.assigned"},
		{CollectionCompletedData{AssignmentID: previous, HandoffID: "64000000-0000-4000-8000-000000000001", CollectorUserID: "USR-005",
			CollectorOrgID: "COL-001", CollectorScopeID: "54000000-0000-4000-8000-000000000001", PickupOccurredAt: Timestamp(c.OccurredAt),
			ActualItemCount: 10, VerificationHash: strings.Repeat("a", 64)}, CollectionCompleted, "batch.collection.completed"},
		{CollectionFailedData{AssignmentID: previous, HandoffID: "64000000-0000-4000-8000-000000000002", CollectorUserID: "USR-005",
			CollectorOrgID: "COL-001", CollectorScopeID: "54000000-0000-4000-8000-000000000001", PickupOccurredAt: Timestamp(c.OccurredAt), FailureReason: "DONOR_UNAVAILABLE"}, CollectionFailed, "batch.collection.failed"},
	}
	for _, tc := range cases {
		t.Run(tc.kind, func(t *testing.T) {
			kind, topic, payload, err := MarshalC4(c, tc.data)
			if err != nil {
				t.Fatal(err)
			}
			if kind != tc.kind || topic != tc.topic {
				t.Fatalf("routing: %s/%s", kind, topic)
			}
			var event map[string]any
			if err = json.Unmarshal(payload, &event); err != nil {
				t.Fatal(err)
			}
			// Compare all required keys to the byte-preserved canonical Task 5 schemas.
			// This verifies wire shape; typed data and repository checks enforce values.
			schemaBytes, err := os.ReadFile("contracts/" + tc.kind + ".v1.schema.json")
			if err != nil {
				t.Fatal(err)
			}
			var schema struct {
				Required   []string `json:"required"`
				Properties map[string]struct {
					Required []string `json:"required"`
				} `json:"properties"`
			}
			if err = json.Unmarshal(schemaBytes, &schema); err != nil {
				t.Fatal(err)
			}
			if len(event) != len(schema.Required) {
				t.Fatalf("unexpected envelope keys: %s", payload)
			}
			for _, key := range schema.Required {
				if _, ok := event[key]; !ok {
					t.Fatalf("missing key %s", key)
				}
			}
			data := event["data"].(map[string]any)
			if len(data) != len(schema.Properties["data"].Required) {
				t.Fatalf("unexpected payload keys: %s", payload)
			}
			for _, key := range schema.Properties["data"].Required {
				if _, ok := data[key]; !ok {
					t.Fatalf("missing data key %s", key)
				}
			}
			if event["claim_epoch"] != c.ClaimEpoch || event["occurred_at"] != "2026-09-19T12:00:00.000123Z" {
				t.Fatal("epoch precision or timestamp lost")
			}
		})
	}
	if _, _, _, err := MarshalC4(c, map[string]string{"event_type": "Recovery"}); err == nil {
		t.Fatal("invented public event accepted")
	}
}
PERSISTENCE_EMBED_018

  mkdir -p "$WORK_DIR/backend/internal/health"
  # Embedded backend/internal/health/checker_test.go
  cat > "$WORK_DIR/backend/internal/health/checker_test.go" <<'PERSISTENCE_EMBED_019'
package health

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestCheckerReturnsReadyWhenBothDependenciesRespond(t *testing.T) {
	checker := NewCheckerWithPingers(
		func(context.Context) error { return nil },
		func(context.Context) error { return nil },
		time.Second,
	)
	if err := checker.Check(context.Background()); err != nil {
		t.Fatalf("expected ready dependencies: %v", err)
	}
}

func TestCheckerReturnsDependencyError(t *testing.T) {
	want := errors.New("mysql unavailable")
	checker := NewCheckerWithPingers(
		func(context.Context) error { return want },
		func(context.Context) error { t.Fatal("redis should not be checked after mysql failure"); return nil },
		time.Second,
	)
	if err := checker.Check(context.Background()); !errors.Is(err, want) {
		t.Fatalf("expected MySQL error, got %v", err)
	}
}

func TestCheckerHonoursContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	checker := NewCheckerWithPingers(
		func(ctx context.Context) error { return ctx.Err() },
		func(context.Context) error { return nil },
		time.Second,
	)
	if err := checker.Check(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("expected cancelled context, got %v", err)
	}
}

func TestCheckerDetailedReturnsDependencyError(t *testing.T) {
	checker := NewCheckerWithPingers(
		func(context.Context) error { return errors.New("mysql unavailable") },
		func(context.Context) error { return nil },
		time.Second,
	)

	_, err := checker.CheckDetailed(context.Background())
	if err == nil {
		t.Fatal("expected dependency error")
	}
}

func TestCheckerDetailedReportsEachDependency(t *testing.T) {
	checker := NewCheckerWithPingers(
		func(context.Context) error { return errors.New("mysql unavailable") },
		func(context.Context) error { return nil },
		time.Second,
	)

	report, _ := checker.CheckDetailed(context.Background())
	if report.Status != "not_ready" || report.MySQL != "unavailable" || report.Redis != "ok" {
		t.Fatalf("unexpected health report: %+v", report)
	}
}
PERSISTENCE_EMBED_019

  mkdir -p "$WORK_DIR/backend/internal/logger"
  # Embedded backend/internal/logger/logger_test.go
  cat > "$WORK_DIR/backend/internal/logger/logger_test.go" <<'PERSISTENCE_EMBED_020'
package logger

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"workflow-api/internal/config"
)

func TestNewWritesJSONToRotatingFile(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "workflow-api.log")
	log, err := New(config.LoggingConfig{
		Level: "info", FilePath: logPath, MaxSizeMB: 1, MaxBackups: 1, MaxAgeDays: 1, Console: false,
	})
	if err != nil {
		t.Fatalf("create logger: %v", err)
	}
	t.Cleanup(func() {
		if err := Close(log); err != nil {
			t.Errorf("close logger: %v", err)
		}
	})
	log.Info("test event")

	contents, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read log file: %v", err)
	}
	if !strings.Contains(string(contents), `"msg":"test event"`) {
		t.Fatalf("expected JSON log entry, got %s", contents)
	}
}
PERSISTENCE_EMBED_020

  mkdir -p "$WORK_DIR/backend/internal/middleware"
  # Embedded backend/internal/middleware/auth_test.go
  cat > "$WORK_DIR/backend/internal/middleware/auth_test.go" <<'PERSISTENCE_EMBED_021'
package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"workflow-api/internal/token"
)

func TestRequireAccessTokensRejectsMissingAuthorization(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(CorrelationID())
	r.GET("/protected", RequireAccessTokens(token.NewService("test", "access", "refresh", "hash", time.Minute, time.Hour), nil), func(c *gin.Context) {
		c.Status(http.StatusOK)
	})

	res := httptest.NewRecorder()
	r.ServeHTTP(res, httptest.NewRequest(http.MethodGet, "/protected", nil))

	if res.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", res.Code)
	}
}
PERSISTENCE_EMBED_021

  mkdir -p "$WORK_DIR/backend/internal/middleware"
  # Embedded backend/internal/middleware/correlation_test.go
  cat > "$WORK_DIR/backend/internal/middleware/correlation_test.go" <<'PERSISTENCE_EMBED_022'
package middleware

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"workflow-api/internal/dto"
)

func TestCorrelationIDGeneratesAndEchoesID(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(CorrelationID())
	r.GET("/test", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"correlationId": GetCorrelationID(c)})
	})

	res := httptest.NewRecorder()
	r.ServeHTTP(res, httptest.NewRequest(http.MethodGet, "/test", nil))

	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", res.Code)
	}
	if res.Header().Get("X-Correlation-ID") == "" {
		t.Fatal("expected generated correlation ID")
	}
}

func TestCorrelationIDRejectsValuesLongerThan100Characters(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(CorrelationID())
	r.GET("/test", func(c *gin.Context) { c.Status(http.StatusOK) })

	res := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/test", nil)
	req.Header.Set("X-Correlation-ID", string(make([]byte, 101)))
	r.ServeHTTP(res, req)

	if res.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", res.Code)
	}
	var response dto.ErrorResponse
	if err := json.Unmarshal(res.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Code != "AUTH_INVALID_REQUEST" {
		t.Fatalf("unexpected error code: %q", response.Code)
	}
}
PERSISTENCE_EMBED_022

  mkdir -p "$WORK_DIR/backend/internal/middleware"
  # Embedded backend/internal/middleware/cors_test.go
  cat > "$WORK_DIR/backend/internal/middleware/cors_test.go" <<'PERSISTENCE_EMBED_023'
package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestCORSAllowsConfiguredUIOrigin(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(CORS())
	r.GET("/api/v1/hello", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/api/v1/hello", nil)
	req.Header.Set("Origin", allowedUIOrigin)
	res := httptest.NewRecorder()
	r.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", res.Code)
	}
	if got := res.Header().Get("Access-Control-Allow-Origin"); got != allowedUIOrigin {
		t.Fatalf("expected allowed origin %q, got %q", allowedUIOrigin, got)
	}
	if got := res.Header().Get("Vary"); got != "Origin" {
		t.Fatalf("expected Vary: Origin, got %q", got)
	}
}

func TestCORSHandlesPreflightForConfiguredUIOrigin(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(CORS())
	r.POST("/api/v1/auth/login", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodOptions, "/api/v1/auth/login", nil)
	req.Header.Set("Origin", allowedUIOrigin)
	req.Header.Set("Access-Control-Request-Method", http.MethodPost)
	req.Header.Set("Access-Control-Request-Headers", "authorization, content-type")
	res := httptest.NewRecorder()
	r.ServeHTTP(res, req)

	if res.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", res.Code)
	}
	if got := res.Header().Get("Access-Control-Allow-Methods"); got != "GET, POST, OPTIONS" {
		t.Fatalf("expected allowed methods %q, got %q", "GET, POST, OPTIONS", got)
	}
	if got := res.Header().Get("Access-Control-Allow-Headers"); got != "Authorization, Content-Type, X-Correlation-ID" {
		t.Fatalf("expected allowed headers %q, got %q", "Authorization, Content-Type, X-Correlation-ID", got)
	}
}

func TestCORSDoesNotAllowOtherOrigins(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(CORS())
	r.GET("/api/v1/hello", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/api/v1/hello", nil)
	req.Header.Set("Origin", "https://example.com")
	res := httptest.NewRecorder()
	r.ServeHTTP(res, req)

	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", res.Code)
	}
	if got := res.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("expected no allow-origin header, got %q", got)
	}
}
PERSISTENCE_EMBED_023

  mkdir -p "$WORK_DIR/backend/internal/middleware"
  # Embedded backend/internal/middleware/rate_limit_test.go
  cat > "$WORK_DIR/backend/internal/middleware/rate_limit_test.go" <<'PERSISTENCE_EMBED_024'
package middleware

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

type limiterStub struct {
	allowed bool
	err     error
}

func (s limiterStub) Allow(context.Context, string) (bool, error) {
	return s.allowed, s.err
}

func TestRateLimitReturns429WhenLimitExceeded(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(CorrelationID())
	r.GET("/test", RateLimit(limiterStub{allowed: false}), func(c *gin.Context) { c.Status(http.StatusOK) })

	res := httptest.NewRecorder()
	r.ServeHTTP(res, httptest.NewRequest(http.MethodGet, "/test", nil))

	if res.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429, got %d", res.Code)
	}
}

func TestRateLimitReturns503WhenRedisIsUnavailable(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(CorrelationID())
	r.GET("/test", RateLimit(limiterStub{err: errors.New("redis unavailable")}), func(c *gin.Context) { c.Status(http.StatusOK) })

	res := httptest.NewRecorder()
	r.ServeHTTP(res, httptest.NewRequest(http.MethodGet, "/test", nil))

	if res.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", res.Code)
	}
	if strings.Contains(res.Body.String(), "redis unavailable") {
		t.Fatalf("response exposed dependency error: %s", res.Body.String())
	}
}
PERSISTENCE_EMBED_024

  mkdir -p "$WORK_DIR/backend/internal/model"
  # Embedded backend/internal/model/entities_test.go
  cat > "$WORK_DIR/backend/internal/model/entities_test.go" <<'PERSISTENCE_EMBED_025'
package model

import (
	"testing"
	"time"
)

func TestEntityTableNamesMatchLiquibaseSchema(t *testing.T) {
	tests := map[string]string{
		"organisation": (Organisation{}).TableName(),
		"role":         (Role{}).TableName(),
		"user":         (User{}).TableName(),
		"session":      (Session{}).TableName(),
		"login_audit":  (LoginAudit{}).TableName(),
	}
	expected := map[string]string{
		"organisation": "organisations",
		"role":         "roles",
		"user":         "users",
		"session":      "sessions",
		"login_audit":  "login_audit",
	}
	for name, want := range expected {
		if tests[name] != want {
			t.Errorf("%s table: expected %q, got %q", name, want, tests[name])
		}
	}
}

func TestSessionIsActiveUsesRevocationState(t *testing.T) {
	now := time.Now().UTC()
	active := Session{ExpiresAt: now.Add(time.Minute)}
	if !active.IsActive(now) {
		t.Fatal("expected unrevoked, unexpired session to be active")
	}
	active.RevokedAt = new(now.Add(-time.Second))
	if active.IsActive(now) {
		t.Fatal("expected revoked session to be inactive")
	}
}
PERSISTENCE_EMBED_025

  mkdir -p "$WORK_DIR/backend/internal/ratelimit"
  # Embedded backend/internal/ratelimit/redis_test.go
  cat > "$WORK_DIR/backend/internal/ratelimit/redis_test.go" <<'PERSISTENCE_EMBED_026'
package ratelimit

import (
	"context"
	"testing"
	"time"
)

func TestRedisLimiterAllowsWhenDisabled(t *testing.T) {
	limiter := NewRedisLimiter(nil, 0, time.Minute)
	allowed, err := limiter.Allow(context.Background(), "test")
	if err != nil {
		t.Fatalf("allow with disabled limiter: %v", err)
	}
	if !allowed {
		t.Fatal("disabled limiter should allow the request")
	}
}

func TestRedisLimiterAllowsWhenWindowIsInvalid(t *testing.T) {
	limiter := NewRedisLimiter(nil, 10, 0)
	allowed, err := limiter.Allow(context.Background(), "test")
	if err != nil {
		t.Fatalf("allow with invalid window: %v", err)
	}
	if !allowed {
		t.Fatal("invalid-window limiter should fail open for local configuration")
	}
}
PERSISTENCE_EMBED_026

  mkdir -p "$WORK_DIR/backend/internal/repository"
  # Embedded backend/internal/repository/assignment_commit_integration_test.go
  cat > "$WORK_DIR/backend/internal/repository/assignment_commit_integration_test.go" <<'PERSISTENCE_EMBED_027'
package repository

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"testing"

	"github.com/go-sql-driver/mysql"
)

func TestAssignmentUnknownCommitMySQL(t *testing.T) {
	dsn := os.Getenv("C4_INTEGRATION_DSN")
	if dsn == "" {
		t.Skip("requires disposable C4 runner")
	}
	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DBName != "c4_clean" {
		t.Fatal("requires c4_clean")
	}
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	n := 9000
	for _, recovery := range []bool{false, true} {
		for _, committed := range []bool{false, true} {
			name := "selection"
			if recovery {
				name = "recovery"
			}
			if committed {
				name += "_committed_ack_lost"
			} else {
				name += "_uncommitted_ack_lost"
			}
			t.Run(name, func(t *testing.T) {
				n++
				f := newC4Fixture(t, db, n)
				req := f.request(SelectApprovedBatch, 0, "unknown-commit-key")
				var candidate RecoveryCandidate
				if recovery {
					_, _, a := f.selectBatch(0, nil)
					result, err := f.r.ExecuteAssignment(context.Background(), f.actors[0], f.terminal(ReportFailedPickup, a, "unknown-recovery-fail"))
					candidate = f.candidate(f.result(result, err))
				}
				connector, err := mysql.NewConnector(cfg)
				if err != nil {
					t.Fatal(err)
				}
				fault := &claimCommitFaultConnector{Connector: connector, commitOnServer: committed}
				faultDB := sql.OpenDB(fault)
				defer faultDB.Close()
				r, err := NewSQLAssignmentRepository(faultDB, f.r.options)
				if err != nil {
					t.Fatal(err)
				}
				r.now = f.r.now
				r.newID = f.r.newID
				before := c4Snapshot(t, db, false)
				var result *AssignmentResult
				if recovery {
					result, err = r.RecoverFailedCollection(context.Background(), RecoveryActor{Principal: c4Service}, candidate)
				} else {
					result, err = r.ExecuteAssignment(context.Background(), f.actors[0], req)
				}
				if fault.commits.Load() != 1 {
					t.Fatalf("ambiguous commit retried %d times", fault.commits.Load())
				}
				if committed {
					f.result(result, err)
					if !result.Replayed {
						t.Fatal("expected durable reconciliation")
					}
					if recovery {
						f.state("APPROVED", 7)
					} else {
						f.state("ASSIGNED", 5)
					}
				} else {
					if result != nil || !errors.Is(err, ErrAssignmentCommitUnknown) {
						t.Fatalf("result=%v err=%v", result, err)
					}
					f.unchanged(before)
				}
			})
		}
	}
}
PERSISTENCE_EMBED_027

  mkdir -p "$WORK_DIR/backend/internal/repository"
  # Embedded backend/internal/repository/assignment_integration_test.go
  cat > "$WORK_DIR/backend/internal/repository/assignment_integration_test.go" <<'PERSISTENCE_EMBED_028'
package repository

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
)

var c4Time = time.Date(2026, 9, 19, 9, 0, 0, 0, time.UTC)

const c4Service = "c4-fixture-recovery"

type c4Fixture struct {
	t               *testing.T
	db              *sql.DB
	r               *SQLAssignmentRepository
	n               int
	clock           atomic.Int64
	ids             atomic.Uint64
	actors          [3]AssignmentActor
	org             string
	scope, pool     string
	batches, claims [2]string
}

type c4Response struct {
	AssignmentID      string  `json:"assignment_id"`
	AssignmentStatus  string  `json:"assignment_status"`
	AssignmentVersion string  `json:"assignment_version"`
	BatchStatus       string  `json:"batch_status"`
	BatchVersion      uint32  `json:"batch_version"`
	HandoffID         *string `json:"handoff_id"`
}

func c4ID(n, kind, sequence int) string {
	return fmt.Sprintf("b4%02x%04x-0000-4000-8000-%012x", kind, n, sequence)
}
func (f *c4Fixture) exec(query string, args ...any) {
	f.t.Helper()
	if _, err := f.db.Exec(query, args...); err != nil {
		f.t.Fatalf("fixture SQL: %v\n%s", err, query)
	}
}
func (f *c4Fixture) scalar(query string, args ...any) string {
	f.t.Helper()
	var value string
	if err := f.db.QueryRow(query, args...).Scan(&value); err != nil {
		f.t.Fatal(err)
	}
	return value
}
func (f *c4Fixture) equal(name, query, expected string, args ...any) {
	f.t.Helper()
	if actual := f.scalar(query, args...); actual != expected {
		f.t.Fatalf("%s: got %s, want %s", name, actual, expected)
	}
}
func (f *c4Fixture) setTime(now time.Time) { f.clock.Store(now.UnixNano()) }
func (f *c4Fixture) result(result *AssignmentResult, err error) c4Response {
	f.t.Helper()
	if err != nil || result == nil || result.Status != 200 {
		f.t.Fatalf("command failed: result=%+v err=%v", result, err)
	}
	var response c4Response
	if err = json.Unmarshal(result.Response, &response); err != nil {
		f.t.Fatal(err)
	}
	return response
}
func (f *c4Fixture) request(command AssignmentCommand, batch int, key string) AssignmentRequest {
	version, _ := strconv.ParseUint(f.scalar(`SELECT version FROM ewaste_batches WHERE id=?`, f.batches[batch]), 10, 32)
	return AssignmentRequest{Command: command, BatchID: f.batches[batch], ClaimID: f.claims[batch], ClaimEpoch: "1", ExpectedBatchVersion: uint32(version),
		IdempotencyKey: fmt.Sprintf("c4-%04d-%s", f.n, key), CorrelationID: fmt.Sprintf("fixture-c4-%04d", f.n)}
}
func (f *c4Fixture) selectBatch(actor int, reason *string) (AssignmentRequest, *AssignmentResult, c4Response) {
	req := f.request(SelectApprovedBatch, 0, fmt.Sprintf("select-%d-%d-key", actor, f.ids.Load()))
	req.Reason = reason
	result, err := f.r.ExecuteAssignment(context.Background(), f.actors[actor], req)
	return req, result, f.result(result, err)
}
func (f *c4Fixture) terminal(command AssignmentCommand, a c4Response, key string) AssignmentRequest {
	req := f.request(command, 0, key)
	req.AssignmentID = a.AssignmentID
	req.ExpectedAssignmentVersion, _ = strconv.ParseInt(a.AssignmentVersion, 10, 64)
	req.PickupOccurredAt = f.r.now()
	if command == RecordCollectionHandoff {
		count := uint32(10)
		name := "Synthetic Representative"
		hash := strings.Repeat("a", 64)
		req.ActualItemCount = &count
		req.DonorRepresentativeName = &name
		req.VerificationHash = &hash
	} else {
		reason := "DONOR_UNAVAILABLE"
		req.FailureReason = &reason
	}
	return req
}
func newC4Fixture(t *testing.T, db *sql.DB, n int) *c4Fixture {
	t.Helper()
	r, err := NewSQLAssignmentRepository(db, AssignmentPersistenceOptions{RetainFor: 24 * time.Hour, TransactionTimeout: 15 * time.Second,
		MaxAttempts: 4, RetryBackoff: 5 * time.Millisecond, RecoveryPrincipal: c4Service})
	if err != nil {
		t.Fatal(err)
	}
	f := &c4Fixture{t: t, db: db, r: r, n: n}
	f.setTime(c4Time)
	r.now = func() time.Time { return time.Unix(0, f.clock.Load()).UTC() }
	r.newID = func() string { return fmt.Sprintf("a440%04x-0000-4000-8000-%012x", n, f.ids.Add(1)) }
	f.org = fmt.Sprintf("C4-COL-%04d", n)
	other := fmt.Sprintf("C4-OTHER-%04d", n)
	for _, org := range []string{f.org, other} {
		f.exec(`INSERT INTO organisations (organisation_id,organisation_name,organisation_type,status,created_at,updated_at)
        VALUES (?,?,'COLLECTION_OPERATOR','ACTIVE',?,?)`, org, org, c4Time, c4Time)
	}
	for i := 0; i < 3; i++ {
		f.actors[i] = AssignmentActor{UserID: fmt.Sprintf("C4-USER-%04d-%d", n, i), SessionID: c4ID(n, 0x51, i)}
		org := f.org
		if i == 2 {
			org = other
		}
		f.exec(`INSERT INTO users (user_id,email,display_name,password_hash,role_code,organisation_id,status,created_at,updated_at)
            VALUES (?,?,?,'fixture-not-a-login-password','COLLECTOR',?,'ACTIVE',?,?)`, f.actors[i].UserID, f.actors[i].UserID+"@c4.test", f.actors[i].UserID, org, c4Time, c4Time)
		f.exec(`INSERT INTO sessions (session_id,user_id,token_hash,issued_at,expires_at) VALUES (?,?,SHA2(?,256),?,?)`,
			f.actors[i].SessionID, f.actors[i].UserID, f.actors[i].SessionID, c4Time.Add(-time.Hour), c4Time.Add(24*time.Hour))
	}
	f.scope = c4ID(n, 0x50, 0)
	f.pool = c4ID(n, 0x90, 0)
	f.exec(`INSERT INTO recycler_collector_scopes VALUES (?,'PROC-001',?,'CENTRAL',1,7,?,NULL,?,?)`, f.scope, f.org, c4Time.Add(-time.Hour), c4Time, c4Time)
	f.exec(`INSERT INTO recycler_capacity_pools VALUES (?,'PROC-001',?,500.00,200.00,1,3,?)`, f.pool, fmt.Sprintf("C4-%04d", n), c4Time)
	// Deterministic accepted-claim prerequisites. C3 repository behaviour has its
	// own regression suite; this fixture does not pretend to execute a claim API.
	for i := 0; i < 2; i++ {
		f.batches[i] = c4ID(n, 0xb0, i)
		f.claims[i] = c4ID(n, 0xc0, i)
		f.exec(`INSERT INTO ewaste_batches
            (id,organization_id,created_by,status,category,quantity,estimated_weight_kg,condition_rating,is_data_bearing,
             zone,collection_deadline,claim_epoch,version,submitted_at,created_at,updated_at)
            VALUES (?,'DON-001','USR-003','MATCHED','ICT_EQUIPMENT',10,100.00,'REPAIRABLE',1,'CENTRAL',?,1,3,?,?,?)`,
			f.batches[i], c4Time.Add(7*24*time.Hour), c4Time.Add(-48*time.Hour), c4Time.Add(-49*time.Hour), c4Time.Add(-time.Hour))
		f.exec(`INSERT INTO batch_claims (id,batch_id,claim_epoch,recycler_org_id,claimed_by,idempotency_key,claimed_at,created_at)
            VALUES (?,?,1,'PROC-001','USR-007',?,?,?)`, f.claims[i], f.batches[i], fmt.Sprintf("c4-%04d-claim-%d-key", n, i), c4Time.Add(-time.Hour), c4Time.Add(-time.Hour))
		f.exec(`INSERT INTO capacity_reservations (id,batch_id,claim_id,capacity_pool_id,reserved_kg,status,reserved_at,version)
            VALUES (?,?,?,?,100.00,'RESERVED',?,1)`, c4ID(n, 0x80, i), f.batches[i], f.claims[i], f.pool, c4Time.Add(-time.Hour))
		f.exec(`UPDATE ewaste_batches SET status='APPROVED',current_claim_id=?,version=4,updated_at=? WHERE id=?`, f.claims[i], c4Time.Add(-time.Hour), f.batches[i])
	}
	return f
}

func c4Snapshot(t *testing.T, db *sql.DB, retainedOnly bool) string {
	t.Helper()
	tables := []string{"batch_claims", "capacity_reservations", "recycler_capacity_pools", "matching_decisions", "matched_results"}
	if !retainedOnly {
		tables = append(tables, "ewaste_batches", "recycler_collector_scopes", "batch_assignments", "batch_handoffs", "assignment_actions", "command_idempotency", "batch_audit_events", "event_outbox")
	}
	var snapshot []any
	for _, table := range tables {
		pk := "id"
		if table == "event_outbox" {
			pk = "event_id"
		}
		rows, err := db.Query("SELECT * FROM " + table + " ORDER BY " + pk)
		if err != nil {
			t.Fatal(err)
		}
		cols, err := rows.Columns()
		if err != nil {
			t.Fatal(err)
		}
		for rows.Next() {
			values := make([]sql.RawBytes, len(cols))
			targets := make([]any, len(cols))
			for i := range values {
				targets[i] = &values[i]
			}
			if err = rows.Scan(targets...); err != nil {
				t.Fatal(err)
			}
			record := []any{table}
			for _, value := range values {
				if value == nil {
					record = append(record, nil)
				} else {
					record = append(record, string(value))
				}
			}
			snapshot = append(snapshot, record)
		}
		if err = rows.Err(); err != nil {
			t.Fatal(err)
		}
		rows.Close()
	}
	body, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}
func (f *c4Fixture) unchanged(before string) {
	f.t.Helper()
	if after := c4Snapshot(f.t, f.db, false); after != before {
		f.t.Fatalf("domain snapshot changed: %s -> %s", before, after)
	}
}
func (f *c4Fixture) retained(before string) {
	f.t.Helper()
	if after := c4Snapshot(f.t, f.db, true); after != before {
		f.t.Fatalf("claim/reservation/pool/matching snapshot changed: %s -> %s", before, after)
	}
}
func (f *c4Fixture) state(status string, version uint32) {
	f.t.Helper()
	f.equal("batch state", `SELECT CONCAT(status,':',version,':',claim_epoch,':',current_claim_id) FROM ewaste_batches WHERE id=?`, fmt.Sprintf("%s:%d:1:%s", status, version, f.claims[0]), f.batches[0])
}
func (f *c4Fixture) candidate(a c4Response) RecoveryCandidate {
	return RecoveryCandidate{BatchID: f.batches[0], AssignmentID: a.AssignmentID, HandoffID: *a.HandoffID, ClaimEpoch: "1", ExpectedBatchVersion: a.BatchVersion}
}
func (f *c4Fixture) event(command *AssignmentResult, kind string, wantDataFields int) map[string]any {
	f.t.Helper()
	var payload, topic, key, batch, commandID, correlation, occurred string
	var version uint32
	var state string
	var seq, schema, attempts int
	err := f.db.QueryRow(`SELECT payload_json,topic,partition_key,batch_id,command_id,correlation_id,
        DATE_FORMAT(occurred_at,'%Y-%m-%dT%H:%i:%s.%fZ'),aggregate_version,sequence_in_command,schema_version,publish_state,attempt_count
        FROM event_outbox WHERE command_id=?`, command.CommandID).Scan(&payload, &topic, &key, &batch, &commandID, &correlation, &occurred, &version, &seq, &schema, &state, &attempts)
	if err != nil {
		f.t.Fatal(err)
	}
	var body map[string]any
	if err = json.Unmarshal([]byte(payload), &body); err != nil {
		f.t.Fatal(err)
	}
	wantTopic := map[string]string{"CollectorAssigned": "batch.collector.assigned", "CollectionCompleted": "batch.collection.completed", "CollectionFailed": "batch.collection.failed"}[kind]
	if len(body) != 11 || topic != wantTopic || key != batch || body["batch_id"] != batch || body["command_id"] != commandID ||
		body["event_type"] != kind || body["correlation_id"] != correlation || body["occurred_at"] != occurred || body["batch_version"] != float64(version) ||
		body["claim_epoch"] != "1" || body["sequence_in_command"] != float64(seq) || seq != 1 || schema != 1 || body["schema_version"] != float64(1) || state != "PENDING" || attempts != 0 {
		f.t.Fatalf("invalid canonical envelope: %s", payload)
	}
	data := body["data"].(map[string]any)
	if len(data) != wantDataFields {
		f.t.Fatalf("data keys: %s", payload)
	}
	for _, private := range []string{"donor_representative_name", "notes", "quantity_discrepancy_reason", "reassignment_reason"} {
		if _, ok := data[private]; ok {
			f.t.Fatalf("private field published: %s", private)
		}
	}
	if kind == "CollectionFailed" {
		if _, ok := data["actual_item_count"]; ok {
			f.t.Fatal("observed failure count published as collection")
		}
		if _, ok := data["verification_hash"]; ok {
			f.t.Fatal("failure proof published")
		}
	}
	return data
}

func TestAssignmentPersistenceMySQL(t *testing.T) {
	dsn := os.Getenv("C4_INTEGRATION_DSN")
	if dsn == "" {
		t.Skip("requires the embedded C4 database phase")
	}
	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DBName != "c4_clean" {
		t.Fatal("requires disposable c4_clean")
	}
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	db.SetMaxOpenConns(120)
	db.SetMaxIdleConns(120)
	if err = db.Ping(); err != nil {
		t.Fatal(err)
	}
	n := 0
	fixture := func(t *testing.T) *c4Fixture { n++; return newC4Fixture(t, db, n) }
	ctx := context.Background()
	service := RecoveryActor{Principal: c4Service}

	t.Run("canonical_failure_recovery_replacement_collection", func(t *testing.T) {
		f := fixture(t)
		retained := c4Snapshot(t, db, true)
		selectReq, selected, a1 := f.selectBatch(0, nil)
		f.state("ASSIGNED", 5)
		data := f.event(selected, "CollectorAssigned", 10)
		if data["assignment_version"] != "1" || data["assignment_sequence"] != "1" || data["previous_assignment_id"] != nil {
			t.Fatal(data)
		}
		f.equal("direct accepted choice", `SELECT CONCAT(assignment_status,':',version,':',assigned_at=responded_at) FROM batch_assignments WHERE id=?`, "ACCEPTED:1:1", a1.AssignmentID)
		f.setTime(c4Time.Add(time.Hour))
		failedReq := f.terminal(ReportFailedPickup, a1, "failed-pickup-key")
		observed := uint32(7)
		failedReq.ActualItemCount = &observed // Not a collected quantity.
		failed, err := f.r.ExecuteAssignment(ctx, f.actors[0], failedReq)
		failure := f.result(failed, err)
		f.state("FAILED_COLLECTION", 6)
		f.event(failed, "CollectionFailed", 7)
		f.equal("failure retained", `SELECT CONCAT(assignment_status,':',version,':',active_batch_id IS NULL) FROM batch_assignments WHERE id=?`, "FAILED:2:1", a1.AssignmentID)
		f.equal("failure has no collected timestamp", `SELECT collected_at IS NULL FROM batch_handoffs WHERE id=?`, "1", *failure.HandoffID)
		candidate := f.candidate(failure)
		// Expiring the old scope/session cannot block separate service recovery.
		f.exec(`UPDATE recycler_collector_scopes SET is_active=0 WHERE id=?`, f.scope)
		f.exec(`UPDATE sessions SET revoked_at=? WHERE session_id=?`, f.r.now(), f.actors[0].SessionID)
		f.setTime(c4Time.Add(2 * time.Hour))
		recovered, err := f.r.RecoverFailedCollection(ctx, service, candidate)
		f.result(recovered, err)
		f.state("APPROVED", 7)
		f.equal("recovery cleared only pointer", `SELECT current_assignment_id IS NULL FROM ewaste_batches WHERE id=?`, "1", f.batches[0])
		f.equal("old assignment unchanged", `SELECT CONCAT(assignment_status,':',version) FROM batch_assignments WHERE id=?`, "FAILED:2", a1.AssignmentID)
		f.equal("recovery is audit only", `SELECT (SELECT COUNT(*) FROM assignment_actions WHERE command_id=?)+(SELECT COUNT(*) FROM event_outbox WHERE command_id=?)`, "0", recovered.CommandID, recovered.CommandID)
		f.equal("recovery service audit", `SELECT COUNT(*) FROM batch_audit_events WHERE command_id=? AND actor_user_id IS NULL AND actor_org_id IS NULL AND service_principal=? AND event_type='CollectionRecoveryApproved' AND assignment_id=?`, "1", recovered.CommandID, c4Service, a1.AssignmentID)
		f.exec(`UPDATE recycler_collector_scopes SET is_active=1 WHERE id=?`, f.scope)
		f.exec(`UPDATE sessions SET revoked_at=NULL WHERE session_id=?`, f.actors[0].SessionID)
		reason := "Different collector after failed pickup"
		same := f.request(SelectApprovedBatch, 0, "same-collector-key")
		same.Reason = &reason
		before := c4Snapshot(t, db, false)
		result, err := f.r.ExecuteAssignment(ctx, f.actors[0], same)
		if result != nil || !errors.Is(err, ErrAssignmentConflict) {
			t.Fatalf("same collector: %v", err)
		}
		f.unchanged(before)
		_, replacement, a2 := f.selectBatch(1, &reason)
		f.state("ASSIGNED", 8)
		data = f.event(replacement, "CollectorAssigned", 10)
		if data["previous_assignment_id"] != a1.AssignmentID || data["assignment_sequence"] != "2" || a2.AssignmentID == a1.AssignmentID {
			t.Fatal(data)
		}
		f.equal("replacement two actions one version", `SELECT CONCAT(COUNT(*),':',MIN(assignment_version),':',MAX(assignment_version)) FROM assignment_actions WHERE command_id=?`, "2:1:1", replacement.CommandID)
		// Original collector can recover the old response after a new collector wins.
		before = c4Snapshot(t, db, false)
		replay, err := f.r.ExecuteAssignment(ctx, f.actors[0], failedReq)
		if err != nil || !replay.Replayed || string(replay.Response) != string(failed.Response) {
			t.Fatalf("late failure replay: %v", err)
		}
		f.unchanged(before)
		before = c4Snapshot(t, db, false)
		candidate.ExpectedBatchVersion = 8
		replay, err = f.r.RecoverFailedCollection(ctx, service, candidate)
		if err != nil || !replay.Replayed || string(replay.Response) != string(recovered.Response) {
			t.Fatalf("late recovery replay: %v", err)
		}
		f.unchanged(before)
		f.setTime(c4Time.Add(3 * time.Hour))
		handoff := f.terminal(RecordCollectionHandoff, a2, "replacement-handoff-key")
		count := uint32(8)
		handoff.ActualItemCount = &count // Confirmed policy: reason optional on mismatch.
		completed, err := f.r.ExecuteAssignment(ctx, f.actors[1], handoff)
		f.result(completed, err)
		f.state("COLLECTED", 9)
		f.event(completed, "CollectionCompleted", 8)
		f.equal("two distinct outcomes retained", `SELECT CONCAT(COUNT(*),':',SUM(pickup_status='FAILED_COLLECTION'),':',SUM(pickup_status='COLLECTED')) FROM batch_handoffs WHERE batch_id=?`, "2:1:1", f.batches[0])
		f.equal("closed completed assignment", `SELECT CONCAT(assignment_status,':',version,':',active_batch_id IS NULL) FROM batch_assignments WHERE id=?`, "COMPLETED:2:1", a2.AssignmentID)
		f.equal("one audit per command", `SELECT COUNT(*) FROM batch_audit_events WHERE batch_id=?`, "5", f.batches[0])
		f.equal("four public facts", `SELECT COUNT(*) FROM event_outbox WHERE batch_id=?`, "4", f.batches[0])
		before = c4Snapshot(t, db, false)
		replay, err = f.r.LookupAssignment(ctx, f.actors[0], selectReq)
		if err != nil || !replay.Replayed || string(replay.Response) != string(selected.Response) {
			t.Fatalf("original selection replay: %v", err)
		}
		f.unchanged(before)
		f.retained(retained)
	})

	t.Run("pre_pickup_rejection", func(t *testing.T) {
		f := fixture(t)
		retained := c4Snapshot(t, db, true)
		_, _, a := f.selectBatch(0, nil)
		req := f.request(RejectAssignment, 0, "reject-before-pickup")
		req.AssignmentID = a.AssignmentID
		req.ExpectedAssignmentVersion = 1
		reason := "Unavailable for this pickup"
		req.Reason = &reason
		result, err := f.r.ExecuteAssignment(ctx, f.actors[0], req)
		f.result(result, err)
		f.state("APPROVED", 6)
		f.equal("superseded retains rejection", `SELECT CONCAT(assignment_status,':',version,':',rejection_reason) FROM batch_assignments WHERE id=?`, "SUPERSEDED:2:"+reason, a.AssignmentID)
		f.equal("no fabricated handoff", `SELECT COUNT(*) FROM batch_handoffs WHERE batch_id=?`, "0", f.batches[0])
		f.equal("only selection public event", `SELECT COUNT(*) FROM event_outbox WHERE batch_id=?`, "1", f.batches[0])
		f.equal("rejected action", `SELECT action_type FROM assignment_actions WHERE command_id=?`, "REJECTED", result.CommandID)
		_, _, a2 := f.selectBatch(1, &reason)
		if a2.AssignmentID == a.AssignmentID {
			t.Fatal("old collector overwritten")
		}
		f.retained(retained)
	})

	t.Run("100_collector_choices_one_winner", func(t *testing.T) {
		f := fixture(t)
		retained := c4Snapshot(t, db, true)
		const count = 100
		start := make(chan struct{})
		var ready, done sync.WaitGroup
		ready.Add(count)
		done.Add(count)
		results := make([]*AssignmentResult, count)
		errs := make([]error, count)
		requests := make([]AssignmentRequest, count)
		for i := 0; i < count; i++ {
			requests[i] = f.request(SelectApprovedBatch, 0, fmt.Sprintf("race-choice-%03d", i))
			go func(i int) {
				defer done.Done()
				ready.Done()
				<-start
				results[i], errs[i] = f.r.ExecuteAssignment(ctx, f.actors[i%2], requests[i])
			}(i)
		}
		ready.Wait()
		began := time.Now()
		close(start)
		done.Wait()
		wins, conflicts := 0, 0
		for i, err := range errs {
			if err == nil {
				wins++
				f.result(results[i], err)
			} else if errors.Is(err, ErrAssignmentConflict) {
				conflicts++
			} else {
				t.Fatalf("contender %d: %v", i, err)
			}
		}
		if wins != 1 || conflicts != 99 {
			t.Fatalf("wins=%d conflicts=%d", wins, conflicts)
		}
		f.state("ASSIGNED", 5)
		for _, table := range []string{"batch_assignments", "assignment_actions", "batch_audit_events", "event_outbox", "command_idempotency"} {
			f.equal("one winner "+table, "SELECT COUNT(*) FROM "+table+" WHERE batch_id=?", "1", f.batches[0])
		}
		f.retained(retained)
		t.Logf("100-way collector selection: winners=%d conflicts=%d elapsed=%s", wins, conflicts, time.Since(began))
	})

	t.Run("success_failure_race_one_terminal_outcome", func(t *testing.T) {
		f := fixture(t)
		retained := c4Snapshot(t, db, true)
		_, _, a := f.selectBatch(0, nil)
		f.setTime(c4Time.Add(time.Hour))
		requests := []AssignmentRequest{f.terminal(RecordCollectionHandoff, a, "success-race-key"), f.terminal(ReportFailedPickup, a, "failure-race-key")}
		start := make(chan struct{})
		var done sync.WaitGroup
		done.Add(2)
		errs := make([]error, 2)
		results := make([]*AssignmentResult, 2)
		for i := range requests {
			go func(i int) {
				defer done.Done()
				<-start
				results[i], errs[i] = f.r.ExecuteAssignment(ctx, f.actors[0], requests[i])
			}(i)
		}
		close(start)
		done.Wait()
		wins := 0
		for i, err := range errs {
			if err == nil {
				wins++
				f.result(results[i], nil)
			} else if !errors.Is(err, ErrAssignmentConflict) {
				t.Fatal(err)
			}
		}
		if wins != 1 {
			t.Fatalf("winners=%d", wins)
		}
		f.equal("one terminal outcome", `SELECT COUNT(*) FROM batch_handoffs WHERE assignment_id=?`, "1", a.AssignmentID)
		f.equal("one terminal event", `SELECT COUNT(*) FROM event_outbox WHERE batch_id=? AND event_type IN ('CollectionCompleted','CollectionFailed')`, "1", f.batches[0])
		f.equal("one version increment", `SELECT version FROM ewaste_batches WHERE id=?`, "6", f.batches[0])
		f.retained(retained)
	})

	t.Run("same_key_concurrency_and_cross_batch_collision", func(t *testing.T) {
		f := fixture(t)
		req := f.request(SelectApprovedBatch, 0, "same-key-choices")
		const count = 12
		start := make(chan struct{})
		var done sync.WaitGroup
		done.Add(count)
		results := make([]*AssignmentResult, count)
		errs := make([]error, count)
		for i := 0; i < count; i++ {
			go func(i int) {
				defer done.Done()
				<-start
				results[i], errs[i] = f.r.ExecuteAssignment(ctx, f.actors[0], req)
			}(i)
		}
		close(start)
		done.Wait()
		fresh := 0
		for i, err := range errs {
			f.result(results[i], err)
			if !results[i].Replayed {
				fresh++
			}
			if string(results[i].Response) != string(results[0].Response) {
				t.Fatal("replay response changed")
			}
		}
		if fresh != 1 {
			t.Fatalf("new commands=%d", fresh)
		}
		changed := req
		changed.BatchID = f.batches[1]
		changed.ClaimID = f.claims[1]
		before := c4Snapshot(t, db, false)
		result, err := f.r.ExecuteAssignment(ctx, f.actors[0], changed)
		if result != nil || !errors.Is(err, ErrAssignmentConflict) {
			t.Fatalf("cross-batch key: %v", err)
		}
		f.unchanged(before)
	})

	for _, legacy := range []AssignmentCommand{AcceptAssignmentLegacy, RejectAssignment, RecordCollectionHandoff, ReportFailedPickup} {
		t.Run("legacy_"+string(legacy), func(t *testing.T) {
			f := fixture(t)
			retained := c4Snapshot(t, db, true)
			_, _, a := f.selectBatch(0, nil)
			f.exec(`UPDATE batch_assignments SET assignment_status='PENDING',responded_at=NULL WHERE id=?`, a.AssignmentID)
			f.setTime(c4Time.Add(time.Hour))
			var req AssignmentRequest
			if legacy == RecordCollectionHandoff || legacy == ReportFailedPickup {
				req = f.terminal(legacy, a, "legacy-pickup-key")
			} else {
				req = f.request(legacy, 0, "legacy-action-key")
				req.AssignmentID = a.AssignmentID
				req.ExpectedAssignmentVersion = 1
			}
			if legacy == RejectAssignment {
				reason := "Legacy rejection"
				req.Reason = &reason
			}
			result, err := f.r.ExecuteAssignment(ctx, f.actors[0], req)
			f.result(result, err)
			if legacy == AcceptAssignmentLegacy {
				f.state("ASSIGNED", 6)
				f.equal("actual acceptance time", `SELECT DATE_FORMAT(responded_at,'%Y-%m-%dT%H:%i:%s.%fZ') FROM batch_assignments WHERE id=?`, "2026-09-19T10:00:00.000000Z", a.AssignmentID)
				f.equal("no acceptance public event", `SELECT COUNT(*) FROM event_outbox WHERE command_id=?`, "0", result.CommandID)
			} else {
				f.equal("legacy closure has no fabricated acceptance", `SELECT responded_at IS NULL AND closed_at IS NOT NULL FROM batch_assignments WHERE id=?`, "1", a.AssignmentID)
			}
			f.equal("legacy provenance", `SELECT JSON_EXTRACT(details_json,'$.legacy_pending') FROM batch_audit_events WHERE command_id=?`, "true", result.CommandID)
			f.retained(retained)
		})
	}

	t.Run("concurrent_automatic_recovery", func(t *testing.T) {
		f := fixture(t)
		_, _, a := f.selectBatch(0, nil)
		req := f.terminal(ReportFailedPickup, a, "recovery-failure-key")
		failed, err := f.r.ExecuteAssignment(ctx, f.actors[0], req)
		outcome := f.result(failed, err)
		candidate := f.candidate(outcome)
		retained := c4Snapshot(t, db, true)
		const count = 12
		start := make(chan struct{})
		var done sync.WaitGroup
		done.Add(count)
		results := make([]*AssignmentResult, count)
		errs := make([]error, count)
		for i := 0; i < count; i++ {
			go func(i int) {
				defer done.Done()
				<-start
				results[i], errs[i] = f.r.RecoverFailedCollection(ctx, service, candidate)
			}(i)
		}
		close(start)
		done.Wait()
		fresh := 0
		for i, err := range errs {
			f.result(results[i], err)
			if !results[i].Replayed {
				fresh++
			}
		}
		if fresh != 1 {
			t.Fatalf("recovery writes=%d", fresh)
		}
		f.state("APPROVED", 7)
		f.equal("one recovery audit", `SELECT COUNT(*) FROM batch_audit_events WHERE batch_id=? AND event_type='CollectionRecoveryApproved'`, "1", f.batches[0])
		f.retained(retained)
	})

	t.Run("automatic_discovery_and_worker", func(t *testing.T) {
		f := fixture(t)
		_, _, a := f.selectBatch(0, nil)
		failed, err := f.r.ExecuteAssignment(ctx, f.actors[0], f.terminal(ReportFailedPickup, a, "worker-failure-key"))
		f.result(failed, err)
		// Discovery is allowed to also recover earlier independent failed fixtures.
		workerCtx, cancel := context.WithCancel(ctx)
		defer cancel()
		seen := false
		err = f.r.RunRecovery(workerCtx, service, RecoveryWorkerOptions{BatchLimit: 100, PollInterval: time.Millisecond, OnAttempt: func(attempt RecoveryAttempt) {
			if attempt.Candidate.BatchID == f.batches[0] {
				f.result(attempt.Result, attempt.Err)
				seen = true
				cancel()
			}
		}})
		if !errors.Is(err, context.Canceled) || !seen {
			t.Fatalf("worker outcome: seen=%t err=%v", seen, err)
		}
		f.state("APPROVED", 7)
	})

	for _, command := range []AssignmentCommand{SelectApprovedBatch, RecordCollectionHandoff, ReportFailedPickup, RejectAssignment, AcceptAssignmentLegacy, RecoverFailedCollection} {
		stages := []string{"command_started", "batch", "audit", "command_completed", "before_commit"}
		if command != RecoverFailedCollection {
			stages = append(stages, "assignment")
		}
		switch command {
		case SelectApprovedBatch:
			stages = append(stages, "action_ASSIGNED", "outbox")
		case RecordCollectionHandoff:
			stages = append(stages, "handoff", "action_HANDOFF_RECORDED", "outbox")
		case ReportFailedPickup:
			stages = append(stages, "handoff", "action_PICKUP_FAILED", "outbox")
		case RejectAssignment:
			stages = append(stages, "action_REJECTED")
		case AcceptAssignmentLegacy:
			stages = append(stages, "action_ACCEPTED")
		}
		for _, stage := range stages {
			t.Run("rollback_"+string(command)+"_"+stage, func(t *testing.T) {
				f := fixture(t)
				var req AssignmentRequest
				var candidate RecoveryCandidate
				if command == SelectApprovedBatch {
					req = f.request(command, 0, "rollback-select-key")
				} else {
					_, _, a := f.selectBatch(0, nil)
					if command == RecoverFailedCollection {
						failed, err := f.r.ExecuteAssignment(ctx, f.actors[0], f.terminal(ReportFailedPickup, a, "rollback-failure-key"))
						candidate = f.candidate(f.result(failed, err))
					} else if command == RecordCollectionHandoff || command == ReportFailedPickup {
						req = f.terminal(command, a, "rollback-handoff-key")
					} else {
						req = f.request(command, 0, "rollback-action-key")
						req.AssignmentID = a.AssignmentID
						req.ExpectedAssignmentVersion = 1
						if command == RejectAssignment {
							reason := "Fixture rejection"
							req.Reason = &reason
						} else {
							f.exec(`UPDATE batch_assignments SET assignment_status='PENDING',responded_at=NULL WHERE id=?`, a.AssignmentID)
						}
					}
				}
				injected := errors.New("fixture write failure")
				f.r.afterWrite = func(point string) error {
					if point == stage {
						return injected
					}
					return nil
				}
				before := c4Snapshot(t, db, false)
				var result *AssignmentResult
				var err error
				if command == RecoverFailedCollection {
					result, err = f.r.RecoverFailedCollection(ctx, service, candidate)
				} else {
					result, err = f.r.ExecuteAssignment(ctx, f.actors[0], req)
				}
				if result != nil || !errors.Is(err, injected) {
					t.Fatalf("stage %s: %v", stage, err)
				}
				f.unchanged(before)
			})
		}
	}

	t.Run("replacement_second_action_rollback", func(t *testing.T) {
		f := fixture(t)
		_, _, a := f.selectBatch(0, nil)
		reason := "Replacement fixture"
		reject := f.request(RejectAssignment, 0, "replacement-reject-key")
		reject.AssignmentID = a.AssignmentID
		reject.ExpectedAssignmentVersion = 1
		reject.Reason = &reason
		result, err := f.r.ExecuteAssignment(ctx, f.actors[0], reject)
		f.result(result, err)
		req := f.request(SelectApprovedBatch, 0, "replacement-fault-key")
		req.Reason = &reason
		injected := errors.New("second action failed")
		f.r.afterWrite = func(stage string) error {
			if stage == "action_REASSIGNED" {
				return injected
			}
			return nil
		}
		before := c4Snapshot(t, db, false)
		result, err = f.r.ExecuteAssignment(ctx, f.actors[1], req)
		if result != nil || !errors.Is(err, injected) {
			t.Fatal(err)
		}
		f.unchanged(before)
	})

	cases := []struct {
		name   string
		mutate func(*c4Fixture, *AssignmentRequest)
		want   error
	}{
		{"wrong_collector", func(f *c4Fixture, r *AssignmentRequest) { f.actors[0] = f.actors[1] }, ErrAssignmentForbidden},
		{"wrong_org", func(f *c4Fixture, r *AssignmentRequest) { f.actors[0] = f.actors[2] }, ErrAssignmentForbidden},
		{"revoked_session", func(f *c4Fixture, r *AssignmentRequest) {
			f.exec(`UPDATE sessions SET revoked_at=? WHERE session_id=?`, f.r.now(), f.actors[0].SessionID)
		}, ErrAssignmentUnauthorized},
		{"expired_session", func(f *c4Fixture, r *AssignmentRequest) {
			f.exec(`UPDATE sessions SET expires_at=? WHERE session_id=?`, f.r.now(), f.actors[0].SessionID)
		}, ErrAssignmentUnauthorized},
		{"inactive_user", func(f *c4Fixture, r *AssignmentRequest) {
			f.exec(`UPDATE users SET status='DISABLED' WHERE user_id=?`, f.actors[0].UserID)
		}, ErrAssignmentUnauthorized},
		{"wrong_role", func(f *c4Fixture, r *AssignmentRequest) {
			f.exec(`UPDATE users SET role_code='DONOR' WHERE user_id=?`, f.actors[0].UserID)
		}, ErrAssignmentForbidden},
		{"inactive_org", func(f *c4Fixture, r *AssignmentRequest) {
			f.exec(`UPDATE organisations SET status='SUSPENDED' WHERE organisation_id=?`, f.org)
		}, ErrAssignmentForbidden},
		{"revoked_scope", func(f *c4Fixture, r *AssignmentRequest) {
			f.exec(`UPDATE recycler_collector_scopes SET is_active=0 WHERE id=?`, f.scope)
		}, ErrAssignmentForbidden},
		{"expired_scope", func(f *c4Fixture, r *AssignmentRequest) {
			f.exec(`UPDATE recycler_collector_scopes SET valid_until=? WHERE id=?`, f.r.now(), f.scope)
		}, ErrAssignmentForbidden},
		{"future_scope", func(f *c4Fixture, r *AssignmentRequest) {
			f.exec(`UPDATE recycler_collector_scopes SET valid_from=? WHERE id=?`, f.r.now().Add(time.Hour), f.scope)
		}, ErrAssignmentForbidden},
		{"wrong_zone", func(f *c4Fixture, r *AssignmentRequest) {
			f.exec(`UPDATE recycler_collector_scopes SET zone='NORTH' WHERE id=?`, f.scope)
		}, ErrAssignmentForbidden},
		{"stale_batch_version", func(f *c4Fixture, r *AssignmentRequest) { r.ExpectedBatchVersion-- }, ErrAssignmentConflict},
		{"stale_assignment_version", func(f *c4Fixture, r *AssignmentRequest) { r.ExpectedAssignmentVersion = 2 }, ErrAssignmentConflict},
		{"stale_epoch", func(f *c4Fixture, r *AssignmentRequest) { r.ClaimEpoch = "2" }, ErrAssignmentConflict},
		{"wrong_claim", func(f *c4Fixture, r *AssignmentRequest) { r.ClaimID = f.claims[1] }, ErrAssignmentConflict},
		{"pickup_before_assignment", func(f *c4Fixture, r *AssignmentRequest) { r.PickupOccurredAt = c4Time.Add(-time.Microsecond) }, ErrAssignmentInvalid},
		{"pickup_after_recording", func(f *c4Fixture, r *AssignmentRequest) { r.PickupOccurredAt = f.r.now().Add(time.Microsecond) }, ErrAssignmentInvalid},
		{"unsafe_reservation", func(f *c4Fixture, r *AssignmentRequest) {
			f.exec(`UPDATE capacity_reservations SET reserved_kg=0.10 WHERE claim_id=?`, f.claims[0])
		}, ErrAssignmentRecoveryUnsafe},
	}
	for _, tc := range cases {
		t.Run("reject_"+tc.name, func(t *testing.T) {
			f := fixture(t)
			_, _, a := f.selectBatch(0, nil)
			req := f.terminal(RecordCollectionHandoff, a, "rejected-handoff-key")
			tc.mutate(f, &req)
			before := c4Snapshot(t, db, false)
			result, err := f.r.ExecuteAssignment(ctx, f.actors[0], req)
			if result != nil || !errors.Is(err, tc.want) {
				t.Fatalf("got %v want %v", err, tc.want)
			}
			f.unchanged(before)
		})
	}

	t.Run("changed_hash_revoked_replay_and_new_key_opposite_outcome", func(t *testing.T) {
		f := fixture(t)
		_, _, a := f.selectBatch(0, nil)
		req := f.terminal(RecordCollectionHandoff, a, "original-handoff-key")
		result, err := f.r.ExecuteAssignment(ctx, f.actors[0], req)
		f.result(result, err)
		changed := req
		notes := "changed"
		changed.Notes = &notes
		before := c4Snapshot(t, db, false)
		got, err := f.r.ExecuteAssignment(ctx, f.actors[0], changed)
		if got != nil || !errors.Is(err, ErrAssignmentConflict) {
			t.Fatal(err)
		}
		f.unchanged(before)
		opposite := f.terminal(ReportFailedPickup, a, "opposite-outcome-key")
		before = c4Snapshot(t, db, false)
		got, err = f.r.ExecuteAssignment(ctx, f.actors[0], opposite)
		if got != nil || !errors.Is(err, ErrAssignmentConflict) {
			t.Fatal(err)
		}
		f.unchanged(before)
		f.exec(`UPDATE recycler_collector_scopes SET is_active=0 WHERE id=?`, f.scope)
		before = c4Snapshot(t, db, false)
		got, err = f.r.LookupAssignment(ctx, f.actors[0], req)
		if got != nil || !errors.Is(err, ErrAssignmentForbidden) {
			t.Fatal(err)
		}
		f.unchanged(before)
	})

	t.Run("unsafe_and_unauthorised_recovery", func(t *testing.T) {
		f := fixture(t)
		_, _, a := f.selectBatch(0, nil)
		result, err := f.r.ExecuteAssignment(ctx, f.actors[0], f.terminal(ReportFailedPickup, a, "unsafe-recovery-fail"))
		c := f.candidate(f.result(result, err))
		before := c4Snapshot(t, db, false)
		result, err = f.r.RecoverFailedCollection(ctx, RecoveryActor{Principal: "other-service"}, c)
		if result != nil || !errors.Is(err, ErrAssignmentForbidden) {
			t.Fatal(err)
		}
		f.unchanged(before)
		f.exec(`UPDATE capacity_reservations SET reserved_kg=0.10 WHERE claim_id=?`, f.claims[0])
		before = c4Snapshot(t, db, false)
		result, err = f.r.RecoverFailedCollection(ctx, service, c)
		if result != nil || !errors.Is(err, ErrAssignmentRecoveryUnsafe) {
			t.Fatal(err)
		}
		f.unchanged(before)
		f.state("FAILED_COLLECTION", 6)
	})

	for _, errno := range []uint16{1213, 1205} {
		t.Run(fmt.Sprintf("whole_transaction_retry_%d", errno), func(t *testing.T) {
			f := fixture(t)
			calls := 0
			f.r.afterWrite = func(stage string) error {
				if stage == "outbox" {
					calls++
					if calls == 1 {
						return &mysql.MySQLError{Number: errno}
					}
				}
				return nil
			}
			_, _, _ = f.selectBatch(0, nil)
			if calls != 2 {
				t.Fatalf("attempts=%d", calls)
			}
			f.state("ASSIGNED", 5)
			f.equal("only committed action retained", `SELECT COUNT(*) FROM assignment_actions WHERE batch_id=?`, "1", f.batches[0])
		})
	}
	t.Run("retry_exhaustion", func(t *testing.T) {
		f := fixture(t)
		calls := 0
		f.r.afterWrite = func(stage string) error {
			if stage == "assignment" {
				calls++
				return &mysql.MySQLError{Number: 1213}
			}
			return nil
		}
		before := c4Snapshot(t, db, false)
		result, err := f.r.ExecuteAssignment(ctx, f.actors[0], f.request(SelectApprovedBatch, 0, "retry-exhaustion-key"))
		if result != nil || !errors.Is(err, ErrAssignmentRetryable) || calls != f.r.options.MaxAttempts {
			t.Fatalf("result=%v error=%v attempts=%d", result, err, calls)
		}
		f.unchanged(before)
	})
	for _, status := range []string{"MATCHED", "ASSIGNED", "FAILED_COLLECTION", "COLLECTED"} {
		t.Run("selection_rejects_"+status, func(t *testing.T) {
			f := fixture(t)
			if status == "MATCHED" {
				f.exec(`UPDATE ewaste_batches SET status='MATCHED',current_claim_id=NULL WHERE id=?`, f.batches[0])
			} else {
				_, _, a := f.selectBatch(0, nil)
				if status != "ASSIGNED" {
					command := RecordCollectionHandoff
					if status == "FAILED_COLLECTION" {
						command = ReportFailedPickup
					}
					result, err := f.r.ExecuteAssignment(ctx, f.actors[0], f.terminal(command, a, "state-outcome-key"))
					f.result(result, err)
				}
			}
			req := f.request(SelectApprovedBatch, 0, "invalid-selection-state")
			before := c4Snapshot(t, db, false)
			result, err := f.r.ExecuteAssignment(ctx, f.actors[1], req)
			if result != nil || !errors.Is(err, ErrAssignmentConflict) {
				t.Fatalf("selection on %s: %v", status, err)
			}
			f.unchanged(before)
		})
	}

	t.Run("cross_batch_same_identity_race", func(t *testing.T) {
		f := fixture(t)
		requests := []AssignmentRequest{f.request(SelectApprovedBatch, 0, "cross-batch-race-key"), f.request(SelectApprovedBatch, 1, "cross-batch-race-key")}
		start := make(chan struct{})
		var done sync.WaitGroup
		done.Add(2)
		results := make([]*AssignmentResult, 2)
		errs := make([]error, 2)
		for i := range requests {
			go func(i int) {
				defer done.Done()
				<-start
				results[i], errs[i] = f.r.ExecuteAssignment(ctx, f.actors[0], requests[i])
			}(i)
		}
		close(start)
		done.Wait()
		wins, conflicts := 0, 0
		for i, err := range errs {
			if err == nil {
				f.result(results[i], err)
				wins++
			} else if errors.Is(err, ErrAssignmentConflict) {
				conflicts++
			} else {
				t.Fatal(err)
			}
		}
		if wins != 1 || conflicts != 1 {
			t.Fatalf("wins=%d conflicts=%d", wins, conflicts)
		}
		for _, table := range []string{"batch_assignments", "assignment_actions", "batch_audit_events", "event_outbox", "command_idempotency"} {
			f.equal("one cross-batch winner "+table, "SELECT COUNT(*) FROM "+table+" WHERE batch_id IN (?,?)", "1", f.batches[0], f.batches[1])
		}
	})

	t.Run("scope_revocation_while_handoff_waits", func(t *testing.T) {
		f := fixture(t)
		_, _, a := f.selectBatch(0, nil)
		req := f.terminal(RecordCollectionHandoff, a, "blocked-handoff-key")
		tx, err := db.BeginTx(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback()
		var id string
		if err = tx.QueryRow(`SELECT id FROM recycler_collector_scopes WHERE id=? FOR UPDATE`, f.scope).Scan(&id); err != nil {
			t.Fatal(err)
		}
		type outcome struct {
			result *AssignmentResult
			err    error
		}
		done := make(chan outcome, 1)
		go func() { result, err := f.r.ExecuteAssignment(ctx, f.actors[0], req); done <- outcome{result, err} }()
		deadline := time.Now().Add(5 * time.Second)
		observed := false
		for time.Now().Before(deadline) {
			var waits int
			if err = db.QueryRow(`SELECT COUNT(*) FROM performance_schema.data_lock_waits`).Scan(&waits); err != nil {
				t.Fatal(err)
			}
			if waits > 0 {
				observed = true
				break
			}
			time.Sleep(5 * time.Millisecond)
		}
		if !observed {
			t.Fatal("handoff never reached scope lock wait")
		}
		if _, err = tx.Exec(`UPDATE recycler_collector_scopes SET is_active=0,version=version+1 WHERE id=?`, f.scope); err != nil {
			t.Fatal(err)
		}
		if err = tx.Commit(); err != nil {
			t.Fatal(err)
		}
		got := <-done
		if got.result != nil || !errors.Is(got.err, ErrAssignmentForbidden) {
			t.Fatalf("revoked after waiting: %v", got.err)
		}
		f.state("ASSIGNED", 5)
		f.equal("no handoff after revocation", `SELECT COUNT(*) FROM batch_handoffs WHERE batch_id=?`, "0", f.batches[0])
		for _, table := range []string{"assignment_actions", "batch_audit_events", "event_outbox", "command_idempotency"} {
			f.equal("only selection remains "+table, "SELECT COUNT(*) FROM "+table+" WHERE batch_id=?", "1", f.batches[0])
		}
		t.Log("observed MySQL scope lock wait; committed revocation rejected handoff without writes")
	})

	t.Run("recovery_pages_past_unsafe_work", func(t *testing.T) {
		blocked := fixture(t)
		_, _, old := blocked.selectBatch(0, nil)
		failed, err := blocked.r.ExecuteAssignment(ctx, blocked.actors[0], blocked.terminal(ReportFailedPickup, old, "blocked-worker-failure"))
		blocked.result(failed, err)
		blocked.exec(`UPDATE capacity_reservations SET reserved_kg=0.10 WHERE claim_id=?`, blocked.claims[0])
		blocked.exec(`UPDATE ewaste_batches SET updated_at=? WHERE id=?`, c4Time.Add(-24*time.Hour), blocked.batches[0])
		f := fixture(t)
		_, _, a := f.selectBatch(0, nil)
		failed, err = f.r.ExecuteAssignment(ctx, f.actors[0], f.terminal(ReportFailedPickup, a, "later-worker-failure"))
		f.result(failed, err)
		workerCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		sawBlocked, recovered := false, false
		err = f.r.RunRecovery(workerCtx, service, RecoveryWorkerOptions{BatchLimit: 1, PollInterval: time.Millisecond, OnAttempt: func(attempt RecoveryAttempt) {
			if attempt.Candidate.BatchID == blocked.batches[0] {
				sawBlocked = errors.Is(attempt.Err, ErrAssignmentRecoveryUnsafe)
			}
			if attempt.Candidate.BatchID == f.batches[0] {
				f.result(attempt.Result, attempt.Err)
				recovered = true
				cancel()
			}
		}})
		if !errors.Is(err, context.Canceled) || !sawBlocked || !recovered {
			t.Fatalf("blocked=%t recovered=%t err=%v", sawBlocked, recovered, err)
		}
		blocked.state("FAILED_COLLECTION", 6)
		f.state("APPROVED", 7)
	})

}
PERSISTENCE_EMBED_028

  mkdir -p "$WORK_DIR/backend/internal/repository"
  # Embedded backend/internal/repository/assignment_test.go
  cat > "$WORK_DIR/backend/internal/repository/assignment_test.go" <<'PERSISTENCE_EMBED_029'
package repository

import (
	"database/sql"
	"errors"
	"strings"
	"testing"
	"time"
)

func validAssignmentRequest() AssignmentRequest {
	return AssignmentRequest{Command: RecordCollectionHandoff,
		BatchID: "b4000000-0000-4000-8000-000000000001", ClaimID: "c4000000-0000-4000-8000-000000000001", ClaimEpoch: "1", ExpectedBatchVersion: 5,
		AssignmentID: "a4000000-0000-4000-8000-000000000001", ExpectedAssignmentVersion: 1, IdempotencyKey: "c4-unit-handoff-key", CorrelationID: "c4-unit",
		PickupOccurredAt: c4Time, DonorRepresentativeName: ptr("Synthetic Donor"), ActualItemCount: ptr(uint32(10)), VerificationHash: ptr(strings.Repeat("a", 64))}
}
func ptr[T any](v T) *T { return &v }

func TestAssignmentInputBoundaries(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*AssignmentRequest)
		valid  bool
	}{
		{"valid_success", func(r *AssignmentRequest) {}, true},
		{"optional_discrepancy", func(r *AssignmentRequest) { r.ActualItemCount = ptr(uint32(7)); r.QuantityDiscrepancyReason = nil }, true},
		{"count_min", func(r *AssignmentRequest) { r.ActualItemCount = ptr(uint32(1)) }, true},
		{"count_max", func(r *AssignmentRequest) { r.ActualItemCount = ptr(uint32(100000)) }, true},
		{"count_zero", func(r *AssignmentRequest) { r.ActualItemCount = ptr(uint32(0)) }, false},
		{"count_large", func(r *AssignmentRequest) { r.ActualItemCount = ptr(uint32(100001)) }, false},
		{"count_missing", func(r *AssignmentRequest) { r.ActualItemCount = nil }, false},
		{"name_missing", func(r *AssignmentRequest) { r.DonorRepresentativeName = nil }, false},
		{"name_blank", func(r *AssignmentRequest) { r.DonorRepresentativeName = ptr("  ") }, false},
		{"name_100_unicode", func(r *AssignmentRequest) { r.DonorRepresentativeName = ptr(strings.Repeat("界", 100)) }, true},
		{"name_101", func(r *AssignmentRequest) { r.DonorRepresentativeName = ptr(strings.Repeat("x", 101)) }, false},
		{"hash_missing", func(r *AssignmentRequest) { r.VerificationHash = nil }, false},
		{"hash_63", func(r *AssignmentRequest) { r.VerificationHash = ptr(strings.Repeat("a", 63)) }, false},
		{"hash_nonhex", func(r *AssignmentRequest) { r.VerificationHash = ptr(strings.Repeat("z", 64)) }, false},
		{"hash_uppercase", func(r *AssignmentRequest) { r.VerificationHash = ptr(strings.Repeat("A", 64)) }, true},
		{"failure_no_fabricated_evidence", func(r *AssignmentRequest) {
			r.Command = ReportFailedPickup
			r.FailureReason = ptr("DONOR_UNAVAILABLE")
			r.DonorRepresentativeName = nil
			r.ActualItemCount = nil
			r.VerificationHash = nil
		}, true},
		{"failure_optional_observed_count", func(r *AssignmentRequest) { r.Command = ReportFailedPickup; r.FailureReason = ptr("INCORRECT_ITEMS") }, true},
		{"failure_missing_reason", func(r *AssignmentRequest) { r.Command = ReportFailedPickup }, false},
		{"failure_unsupported_reason", func(r *AssignmentRequest) { r.Command = ReportFailedPickup; r.FailureReason = ptr("OTHER") }, false},
		{"success_has_failure_reason", func(r *AssignmentRequest) { r.FailureReason = ptr("ACCESS_DENIED") }, false},
		{"blank_optional_reason", func(r *AssignmentRequest) { r.QuantityDiscrepancyReason = ptr(" ") }, false},
		{"reason_255_unicode", func(r *AssignmentRequest) { r.QuantityDiscrepancyReason = ptr(strings.Repeat("界", 255)) }, true},
		{"notes_500_unicode", func(r *AssignmentRequest) { r.Notes = ptr(strings.Repeat("界", 500)) }, true},
		{"notes_501", func(r *AssignmentRequest) { r.Notes = ptr(strings.Repeat("x", 501)) }, false},
		{"notes_invalid_utf8", func(r *AssignmentRequest) { r.Notes = ptr(string([]byte{0xff})) }, false},
		{"epoch_max", func(r *AssignmentRequest) { r.ClaimEpoch = "18446744073709551615" }, true},
		{"epoch_overflow", func(r *AssignmentRequest) { r.ClaimEpoch = "18446744073709551616" }, false},
		{"epoch_leading_zero", func(r *AssignmentRequest) { r.ClaimEpoch = "01" }, false},
		{"assignment_version_zero", func(r *AssignmentRequest) { r.ExpectedAssignmentVersion = 0 }, false},
		{"batch_version_zero", func(r *AssignmentRequest) { r.ExpectedBatchVersion = 0 }, false},
		{"non_uuid", func(r *AssignmentRequest) { r.AssignmentID = "assignment" }, false},
		{"key_15", func(r *AssignmentRequest) { r.IdempotencyKey = strings.Repeat("x", 15) }, false},
		{"key_64", func(r *AssignmentRequest) { r.IdempotencyKey = strings.Repeat("x", 64) }, true},
		{"key_65", func(r *AssignmentRequest) { r.IdempotencyKey = strings.Repeat("x", 65) }, false},
		{"key_non_ascii", func(r *AssignmentRequest) { r.IdempotencyKey = strings.Repeat("界", 16) }, false},
		{"timestamp_nanoseconds_rejected", func(r *AssignmentRequest) { r.PickupOccurredAt = r.PickupOccurredAt.Add(time.Nanosecond) }, false},
		{"missing_timestamp", func(r *AssignmentRequest) { r.PickupOccurredAt = time.Time{} }, false},
		{"unknown_command", func(r *AssignmentRequest) { r.Command = "Unknown" }, false},
		{"recovery_not_collector_command", func(r *AssignmentRequest) { r.Command = RecoverFailedCollection }, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := validAssignmentRequest()
			tc.mutate(&req)
			err := validateAssignmentRequest(req)
			if tc.valid && err != nil {
				t.Fatal(err)
			}
			if !tc.valid && !errors.Is(err, ErrAssignmentInvalid) {
				t.Fatalf("got %v", err)
			}
		})
	}
}

func TestAssignmentReplayHash(t *testing.T) {
	a := assignmentIdentity{user: "USR-005", org: "COL-001", scope: "user:USR-005"}
	req := validAssignmentRequest()
	original, err := assignmentHash(a, req)
	if err != nil {
		t.Fatal(err)
	}
	req.CorrelationID = "different transport"
	req.IdempotencyKey = "Other-Key-01234567"
	transport, _ := assignmentHash(a, req)
	if transport != original {
		t.Fatal("transport changed hash")
	}
	req.Notes = ptr("")
	changed, _ := assignmentHash(a, req)
	if changed == original {
		t.Fatal("nil and empty notes collapsed")
	}
	req = validAssignmentRequest()
	req.PickupOccurredAt = req.PickupOccurredAt.Add(time.Microsecond)
	changed, _ = assignmentHash(a, req)
	if changed == original {
		t.Fatal("pickup time omitted from hash")
	}
	req = validAssignmentRequest()
	a.org = "COL-002"
	changed, _ = assignmentHash(a, req)
	if changed == original {
		t.Fatal("organisation omitted from hash")
	}
}

func TestRecoveryIdentityExcludesRefreshedVersion(t *testing.T) {
	c := RecoveryCandidate{BatchID: "b4000000-0000-4000-8000-000000000001", AssignmentID: "a4000000-0000-4000-8000-000000000001", HandoffID: "64000000-0000-4000-8000-000000000001", ClaimEpoch: "1", ExpectedBatchVersion: 6}
	key, hash, err := recoveryInput(c)
	if err != nil {
		t.Fatal(err)
	}
	c.ExpectedBatchVersion = 9
	key2, hash2, err := recoveryInput(c)
	if err != nil || key2 != key || hash2 != hash {
		t.Fatal("refreshed version changed recovery identity")
	}
	c.ClaimEpoch = "2"
	_, changed, _ := recoveryInput(c)
	if changed == hash {
		t.Fatal("epoch omitted from recovery hash")
	}
}

func TestAssignmentRequiresExplicitSettings(t *testing.T) {
	if _, err := NewSQLAssignmentRepository(&sql.DB{}, AssignmentPersistenceOptions{}); err == nil {
		t.Fatal("implicit defaults accepted")
	}
	opts := AssignmentPersistenceOptions{RetainFor: time.Hour, TransactionTimeout: time.Second, MaxAttempts: 2, RetryBackoff: time.Millisecond, RecoveryPrincipal: "fixture-recovery"}
	if _, err := NewSQLAssignmentRepository(nil, opts); err == nil {
		t.Fatal("nil DB accepted")
	}
	if _, err := NewSQLAssignmentRepository(&sql.DB{}, opts); err != nil {
		t.Fatal(err)
	}
}
PERSISTENCE_EMBED_029

  mkdir -p "$WORK_DIR/backend/internal/repository"
  # Embedded backend/internal/repository/auth_test.go
  cat > "$WORK_DIR/backend/internal/repository/auth_test.go" <<'PERSISTENCE_EMBED_030'
package repository

import (
	"errors"
	"testing"
)

func TestGormAuthRepositoryImplementsAuthRepository(t *testing.T) {
	var _ AuthRepository = (*GormAuthRepository)(nil)
}

func TestRepositorySentinelErrorsAreDistinct(t *testing.T) {
	if errors.Is(ErrNotFound, ErrRotationRejected) || errors.Is(ErrRotationRejected, ErrNotFound) {
		t.Fatal("repository sentinel errors must remain distinguishable")
	}
}
PERSISTENCE_EMBED_030

  mkdir -p "$WORK_DIR/backend/internal/repository"
  # Embedded backend/internal/repository/claim_commit_integration_test.go
  cat > "$WORK_DIR/backend/internal/repository/claim_commit_integration_test.go" <<'PERSISTENCE_EMBED_031'
package repository

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"os"
	"sync/atomic"
	"testing"

	"github.com/go-sql-driver/mysql"
)

// Wrap the real MySQL transaction: lose the first COMMIT acknowledgement after
// either committing or rolling back on the server. No repository write is mocked.
type claimCommitFaultConnector struct {
	driver.Connector
	commits        atomic.Int32
	commitOnServer bool
}

type claimCommitFaultConn struct {
	driver.Conn
	owner *claimCommitFaultConnector
}

type claimCommitFaultTx struct {
	driver.Tx
	owner *claimCommitFaultConnector
}

func (c *claimCommitFaultConnector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.Connector.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return &claimCommitFaultConn{Conn: conn, owner: c}, nil
}

func (c *claimCommitFaultConn) BeginTx(ctx context.Context, opts driver.TxOptions) (driver.Tx, error) {
	tx, err := c.Conn.(driver.ConnBeginTx).BeginTx(ctx, opts)
	if err != nil {
		return nil, err
	}
	return &claimCommitFaultTx{Tx: tx, owner: c.owner}, nil
}

func (tx *claimCommitFaultTx) Commit() error {
	if tx.owner.commits.Add(1) != 1 {
		return tx.Tx.Commit()
	}
	if tx.owner.commitOnServer {
		if err := tx.Tx.Commit(); err != nil {
			return err
		}
	} else {
		if err := tx.Tx.Rollback(); err != nil {
			return err
		}
	}
	return io.ErrUnexpectedEOF
}

func TestClaimUnknownCommitMySQL(t *testing.T) {
	dsn := os.Getenv("C3_INTEGRATION_DSN")
	if dsn == "" {
		t.Skip("requires disposable MySQL runner")
	}
	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DBName != "c3_clean" {
		t.Fatal("requires c3_clean")
	}
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for i, committed := range []bool{false, true} {
		name := "not_committed"
		if committed {
			name = "committed_response_lost"
		}
		t.Run(name, func(t *testing.T) {
			f := newClaimFixture(t, db, 90+i)
			connector, err := mysql.NewConnector(cfg)
			if err != nil {
				t.Fatal(err)
			}
			fault := &claimCommitFaultConnector{Connector: connector, commitOnServer: committed}
			faultDB := sql.OpenDB(fault)
			defer faultDB.Close()
			r, err := NewSQLClaimRepository(faultDB, f.r.options)
			if err != nil {
				t.Fatal(err)
			}
			r.now = f.r.now
			before := claimSnapshot(t, db)
			req := f.request(0, "unknown-commit-key")
			result, err := r.Claim(context.Background(), f.actors[0], req)
			if fault.commits.Load() != 1 {
				t.Fatalf("ambiguous commit retried %d times", fault.commits.Load())
			}
			if committed {
				if err != nil || result == nil || !result.Replayed {
					t.Fatalf("durable reconciliation: %+v %v", result, err)
				}
				f.success(0, result)
				f.equal("one capacity change", `SELECT CONCAT(reserved_kg,':',version) FROM recycler_capacity_pools WHERE id=?`, "200.00:8", f.pools[0])
			} else {
				if result != nil || !errors.Is(err, ErrClaimCommitUnknown) {
					t.Fatalf("unknown result must not be reported as success: %+v %v", result, err)
				}
				f.unchanged(before)
				// A later authorised retry with the same identity is safe after
				// reconciliation has established there is no durable completion.
				result, err = f.r.Claim(context.Background(), f.actors[0], req)
				if err != nil {
					t.Fatal(err)
				}
				f.success(0, result)
			}
		})
	}
}
PERSISTENCE_EMBED_031

  mkdir -p "$WORK_DIR/backend/internal/repository"
  # Embedded backend/internal/repository/claim_integration_test.go
  cat > "$WORK_DIR/backend/internal/repository/claim_integration_test.go" <<'PERSISTENCE_EMBED_032'
package repository

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-sql-driver/mysql"
)

var claimFixtureTime = time.Date(2026, 9, 18, 10, 0, 0, 0, time.UTC)

type claimFixture struct {
	t       *testing.T
	db      *sql.DB
	r       *SQLClaimRepository
	n       int
	actors  [2]ClaimActor
	orgs    [2]string
	pools   [2]string
	batches [2]string
}

func fixtureID(kind, n, suffix int) string {
	return fmt.Sprintf("%08x-0000-4000-8000-%012x", kind, n*100+suffix)
}

func (f *claimFixture) exec(query string, args ...any) {
	f.t.Helper()
	if _, err := f.db.Exec(query, args...); err != nil {
		f.t.Fatalf("fixture SQL: %v\n%s", err, query)
	}
}

func (f *claimFixture) scalar(query string, args ...any) string {
	f.t.Helper()
	var value string
	if err := f.db.QueryRow(query, args...).Scan(&value); err != nil {
		f.t.Fatal(err)
	}
	return value
}

func (f *claimFixture) equal(name, query, expected string, args ...any) {
	f.t.Helper()
	if actual := f.scalar(query, args...); actual != expected {
		f.t.Fatalf("%s: got %s want %s", name, actual, expected)
	}
}

func (f *claimFixture) request(batch int, key string) ClaimRequest {
	return ClaimRequest{BatchID: f.batches[batch], ExpectedVersion: 3, ClaimEpoch: "1",
		IdempotencyKey: fmt.Sprintf("c3-%03d-%s", f.n, key), CorrelationID: fmt.Sprintf("c3-fixture-%03d", f.n)}
}

func newClaimFixture(t *testing.T, db *sql.DB, n int) *claimFixture {
	t.Helper()
	r, err := NewSQLClaimRepository(db, ClaimPersistenceOptions{RetainFor: 24 * time.Hour,
		TransactionTimeout: 15 * time.Second, MaxAttempts: 4, RetryBackoff: 5 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	r.now = func() time.Time { return claimFixtureTime }
	f := &claimFixture{t: t, db: db, r: r, n: n}
	for i := 0; i < 2; i++ {
		f.orgs[i] = fmt.Sprintf("C3-ORG-%03d-%d", n, i)
		f.actors[i] = ClaimActor{UserID: fmt.Sprintf("C3-USER-%03d-%d", n, i), SessionID: fixtureID(0x53000000, n, i)}
		f.pools[i] = fixtureID(0xd3100000, n, i)
		f.batches[i] = fixtureID(0xb3100000, n, i)
		f.exec(`INSERT INTO organisations (organisation_id,organisation_name,organisation_type,status,created_at,updated_at)
            VALUES (?,?,'PROCESSING_FACILITY','ACTIVE',?,?)`, f.orgs[i], f.orgs[i], claimFixtureTime, claimFixtureTime)
		f.exec(`INSERT INTO users (user_id,email,display_name,password_hash,role_code,organisation_id,status,created_at,updated_at)
            VALUES (?,?,?,'fixture-not-a-login-password','RECYCLER',?,'ACTIVE',?,?)`, f.actors[i].UserID, f.actors[i].UserID+"@c3.test", f.actors[i].UserID, f.orgs[i], claimFixtureTime, claimFixtureTime)
		f.exec(`INSERT INTO sessions (session_id,user_id,token_hash,issued_at,expires_at) VALUES (?,?,SHA2(?,256),?,?)`,
			f.actors[i].SessionID, f.actors[i].UserID, f.actors[i].SessionID, claimFixtureTime.Add(-time.Hour), claimFixtureTime.Add(time.Hour))
		f.exec(`INSERT INTO recycler_matching_profiles VALUES (?,1,1,?,?)`, f.orgs[i], claimFixtureTime, claimFixtureTime)
		f.exec(`INSERT INTO recycler_capacity_pools VALUES (?,?,'SHARED',1000.00,100.00,1,7,?)`, f.pools[i], f.orgs[i], claimFixtureTime)
		f.exec(`INSERT INTO recycler_category_capabilities VALUES (?,?,'ICT_EQUIPMENT','["REPAIRABLE"]',1,1,?,1,?)`, fixtureID(0xca000000, n, i), f.orgs[i], f.pools[i], claimFixtureTime)
		f.exec(`INSERT INTO recycler_service_zones VALUES (?,?,'CENTRAL',60,1,1,?)`, fixtureID(0x2a000000, n, i), f.orgs[i], claimFixtureTime)
	}
	rule := fixtureID(0x71000000, n, 0)
	f.exec(`INSERT INTO matching_rule_sets VALUES (?,?,'{}',?,NULL,'USR-001',?)`, rule, fmt.Sprintf("c3-fixture-%03d", n), claimFixtureTime, claimFixtureTime)
	for i := 0; i < 2; i++ {
		f.exec(`INSERT INTO ewaste_batches
            (id,organization_id,created_by,status,category,quantity,estimated_weight_kg,condition_rating,
             is_data_bearing,zone,collection_deadline,claim_epoch,version,submitted_at,created_at,updated_at)
            VALUES (?,'DON-001','USR-003','MATCHED','ICT_EQUIPMENT',5,100.00,'REPAIRABLE',1,'CENTRAL',?,1,3,?,?,?)`,
			f.batches[i], claimFixtureTime.Add(7*24*time.Hour), claimFixtureTime.Add(-24*time.Hour), claimFixtureTime.Add(-25*time.Hour), claimFixtureTime)
		decision := fixtureID(0xde000000, n, i)
		f.exec(`INSERT INTO matching_decisions VALUES (?,?,?,'REQUEST_SUBMITTED',2,1,?,?,SHA2('input',256),SHA2('profile',256),'{}','MATCHED','ELIGIBLE_EXISTS',2,2,?,?,?)`,
			decision, f.batches[i], fixtureID(0x77000000, n, i), rule, claimFixtureTime, fmt.Sprintf("fixture-%d", n), claimFixtureTime, claimFixtureTime)
		for j := 0; j < 2; j++ {
			f.exec(`INSERT INTO matched_results VALUES (?,?,?,?,1,1,1,1,1,1,1,900.00,?,7,60,?,'ELIGIBLE','[]','{}',?)`,
				fixtureID(0xfa000000, n, i*2+j), decision, f.batches[i], f.orgs[j], f.pools[j], claimFixtureTime.Add(time.Hour), claimFixtureTime)
		}
	}
	return f
}

func claimSnapshot(t *testing.T, db *sql.DB) string {
	t.Helper()
	// Complete row snapshots, including every candidate pool and durable replay.
	var snapshot []any
	for _, table := range []string{"ewaste_batches", "batch_claims", "capacity_reservations", "recycler_capacity_pools",
		"command_idempotency", "batch_audit_events", "event_outbox", "matching_decisions", "matched_results"} {
		pk := "id"
		if table == "event_outbox" {
			pk = "event_id"
		}
		rows, err := db.Query("SELECT * FROM " + table + " ORDER BY " + pk)
		if err != nil {
			t.Fatal(err)
		}
		columns, err := rows.Columns()
		if err != nil {
			t.Fatal(err)
		}
		for rows.Next() {
			values := make([]sql.RawBytes, len(columns))
			targets := make([]any, len(columns))
			for i := range values {
				targets[i] = &values[i]
			}
			if err := rows.Scan(targets...); err != nil {
				t.Fatal(err)
			}
			record := []any{table}
			for _, v := range values {
				if v == nil {
					record = append(record, nil)
				} else {
					record = append(record, string(v))
				}
			}
			snapshot = append(snapshot, record)
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		rows.Close()
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

func (f *claimFixture) unchanged(before string) {
	f.t.Helper()
	if after := claimSnapshot(f.t, f.db); after != before {
		f.t.Fatalf("domain snapshot changed: before=%s after=%s", before, after)
	}
}

func (f *claimFixture) success(batch int, result *ClaimResult) {
	f.t.Helper()
	if result == nil || result.Status != 200 {
		f.t.Fatalf("expected saved 200, got %+v", result)
	}
	f.equal("atomic claim evidence", `SELECT COUNT(*) FROM ewaste_batches b
        JOIN batch_claims c ON c.id=b.current_claim_id AND c.batch_id=b.id AND c.claim_epoch=b.claim_epoch
        JOIN capacity_reservations r ON r.claim_id=c.id AND r.batch_id=b.id
        JOIN recycler_capacity_pools p ON p.id=r.capacity_pool_id AND p.recycler_org_id=c.recycler_org_id
        JOIN command_idempotency i ON i.batch_id=b.id AND i.id=?
        JOIN batch_audit_events a ON a.command_id=i.id AND a.batch_id=b.id AND a.claim_id=c.id
        JOIN event_outbox e ON e.command_id=i.id AND e.batch_id=b.id
        WHERE b.id=? AND b.status='APPROVED' AND b.version=4 AND b.claim_epoch=1
        AND b.current_assignment_id IS NULL AND b.submitted_at='2026-09-17 10:00:00'
        AND c.claim_status='ACCEPTED' AND r.status='RESERVED' AND r.reserved_kg=b.estimated_weight_kg AND r.version=1
        AND i.state='COMPLETED' AND i.response_status=200 AND i.actor_user_id=c.claimed_by
        AND a.event_type='ClaimConfirmed' AND a.from_status='MATCHED' AND a.to_status='APPROVED'
        AND a.batch_version=4 AND a.sequence_in_command=1 AND a.assignment_id IS NULL
        AND JSON_UNQUOTE(JSON_EXTRACT(a.details_json,'$.reservation_id'))=r.id
        AND JSON_UNQUOTE(JSON_EXTRACT(a.details_json,'$.capacity_pool_id'))=p.id
        AND JSON_UNQUOTE(JSON_EXTRACT(a.details_json,'$.decision_id')) IN (SELECT id FROM matching_decisions WHERE batch_id=b.id)
        AND JSON_UNQUOTE(JSON_EXTRACT(a.details_json,'$.matched_result_id')) IN (SELECT id FROM matched_results WHERE batch_id=b.id AND recycler_org_id=c.recycler_org_id)
        AND e.event_type='ClaimConfirmed' AND e.topic='ewaste.claim.events' AND e.aggregate_version=4
        AND e.sequence_in_command=1 AND e.partition_key=b.id AND e.publish_state='PENDING'
        AND e.attempt_count=0 AND e.published_at IS NULL
        AND JSON_UNQUOTE(JSON_EXTRACT(e.payload_json,'$.event_id'))=e.event_id
        AND JSON_UNQUOTE(JSON_EXTRACT(e.payload_json,'$.command_id'))=i.id
        AND JSON_UNQUOTE(JSON_EXTRACT(e.payload_json,'$.batch_id'))=b.id
        AND JSON_EXTRACT(e.payload_json,'$.batch_version')=4
        AND JSON_TYPE(JSON_EXTRACT(e.payload_json,'$.claim_epoch'))='STRING'
        AND JSON_UNQUOTE(JSON_EXTRACT(e.payload_json,'$.claim_epoch'))='1'
        AND JSON_UNQUOTE(JSON_EXTRACT(e.payload_json,'$.data.claim_id'))=c.id
        AND JSON_UNQUOTE(JSON_EXTRACT(e.payload_json,'$.data.recycler_org_id'))=c.recycler_org_id
        AND JSON_UNQUOTE(JSON_EXTRACT(e.payload_json,'$.data.actor_user_id'))=c.claimed_by
        AND JSON_LENGTH(JSON_EXTRACT(e.payload_json,'$.data'))=4`, "1", result.CommandID, f.batches[batch])
	f.equal("one claim", `SELECT COUNT(*) FROM batch_claims WHERE batch_id=?`, "1", f.batches[batch])
	f.equal("one event", `SELECT COUNT(*) FROM event_outbox WHERE batch_id=?`, "1", f.batches[batch])
}

func TestClaimPersistenceMySQL(t *testing.T) {
	dsn := os.Getenv("C3_INTEGRATION_DSN")
	if dsn == "" {
		t.Skip("C3_INTEGRATION_DSN is required; run the embedded C3 database phase")
	}
	cfg, err := mysql.ParseDSN(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DBName != "c3_clean" {
		t.Fatal("integration fixtures require the runner's disposable c3_clean database")
	}
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	db.SetMaxOpenConns(120)
	db.SetMaxIdleConns(120)
	if err = db.Ping(); err != nil {
		t.Fatal(err)
	}
	n := 0
	fixture := func(t *testing.T) *claimFixture { n++; return newClaimFixture(t, db, n) }
	ctx := context.Background()

	t.Run("100_distinct_keys_one_winner", func(t *testing.T) {
		f := fixture(t)
		const count = 100
		start := make(chan struct{})
		var ready, done sync.WaitGroup
		ready.Add(count)
		done.Add(count)
		results := make([]*ClaimResult, count)
		errs := make([]error, count)
		for i := 0; i < count; i++ {
			go func(i int) {
				defer done.Done()
				ready.Done()
				<-start
				results[i], errs[i] = f.r.Claim(ctx, f.actors[i%2], f.request(0, fmt.Sprintf("race-key-%03d", i)))
			}(i)
		}
		ready.Wait()
		began := time.Now()
		close(start)
		done.Wait()
		elapsed := time.Since(began)
		winners, conflicts := 0, 0
		for i, err := range errs {
			if err == nil {
				winners++
				if results[i].Replayed {
					t.Fatal("distinct key replayed")
				}
				f.success(0, results[i])
			} else if errors.Is(err, ErrClaimConflict) {
				conflicts++
			} else {
				t.Fatalf("contender %d: %v", i, err)
			}
		}
		if winners != 1 || conflicts != 99 {
			t.Fatalf("winners=%d conflicts=%d", winners, conflicts)
		}
		f.equal("all candidate pool delta", `SELECT CONCAT(SUM(reserved_kg),':',SUM(version)) FROM recycler_capacity_pools WHERE id IN (?,?)`, "300.00:15", f.pools[0], f.pools[1])
		t.Logf("100-way race: winners=%d conflicts=%d elapsed=%s reference_2s_met=%t (local observation, not an SLA)", winners, conflicts, elapsed, elapsed <= 2*time.Second)
	})
	t.Run("same_key_concurrency_and_response_loss", func(t *testing.T) {
		f := fixture(t)
		req := f.request(0, "same-key-0001")
		const count = 12
		start := make(chan struct{})
		var done sync.WaitGroup
		done.Add(count)
		results := make([]*ClaimResult, count)
		errs := make([]error, count)
		for i := 0; i < count; i++ {
			go func(i int) { defer done.Done(); <-start; results[i], errs[i] = f.r.Claim(ctx, f.actors[0], req) }(i)
		}
		close(start)
		done.Wait()
		fresh := 0
		for i, err := range errs {
			if err != nil {
				t.Fatal(err)
			}
			if !results[i].Replayed {
				fresh++
			}
			if string(results[i].Response) != string(results[0].Response) {
				t.Fatal("different replay response")
			}
		}
		if fresh != 1 {
			t.Fatalf("new writes=%d", fresh)
		}
		f.success(0, results[0])
		before := claimSnapshot(t, db)
		// New repository instance has no cache. Correlation changes are transport-only.
		freshRepo, _ := NewSQLClaimRepository(db, f.r.options)
		freshRepo.now = f.r.now
		req.CorrelationID = "different-transport-correlation"
		replay, err := freshRepo.LookupClaim(ctx, f.actors[0], req)
		if err != nil || replay == nil || !replay.Replayed {
			t.Fatalf("durable response recovery: %v", err)
		}
		if string(replay.Response) != string(results[0].Response) {
			t.Fatal("original response not preserved")
		}
		f.unchanged(before)
		// Schema-level later-state fixture only; no collector command is implemented.
		f.exec(`UPDATE ewaste_batches SET status='COMPLETED',version=9,updated_at=? WHERE id=?`, claimFixtureTime, f.batches[0])
		before = claimSnapshot(t, db)
		replay, err = freshRepo.Claim(ctx, f.actors[0], req)
		if err != nil || !replay.Replayed {
			t.Fatalf("later-state replay: %v", err)
		}
		f.unchanged(before)
		f.exec(`UPDATE sessions SET revoked_at=? WHERE session_id=?`, claimFixtureTime, f.actors[0].SessionID)
		before = claimSnapshot(t, db)
		result, err := freshRepo.LookupClaim(ctx, f.actors[0], req)
		if result != nil || !errors.Is(err, ErrClaimUnauthorized) {
			t.Fatalf("revoked replay leaked: %+v %v", result, err)
		}
		f.unchanged(before)
	})
	t.Run("hash_and_global_key_collisions", func(t *testing.T) {
		f := fixture(t)
		req := f.request(0, "Mixed-Case-Key")
		original, err := f.r.Claim(ctx, f.actors[0], req)
		if err != nil {
			t.Fatal(err)
		}
		f.success(0, original)
		for _, which := range []string{"notes", "other_actor", "case_only", "other_batch"} {
			t.Run(which, func(t *testing.T) {
				changed := req
				actor := f.actors[0]
				switch which {
				case "notes":
					v := "changed"
					changed.Notes = &v
				case "other_actor":
					actor = f.actors[1]
					changed.BatchID = f.batches[1]
				case "case_only":
					changed.IdempotencyKey = strings.ToLower(req.IdempotencyKey)
					changed.BatchID = f.batches[1]
				case "other_batch":
					changed.BatchID = f.batches[1]
				}
				before := claimSnapshot(t, db)
				result, err := f.r.Claim(ctx, actor, changed)
				if result != nil || !errors.Is(err, ErrClaimConflict) {
					t.Fatalf("collision response: %+v %v", result, err)
				}
				f.unchanged(before)
			})
		}
	})
	t.Run("same_key_cross_batch_race", func(t *testing.T) {
		f := fixture(t)
		start := make(chan struct{})
		var done sync.WaitGroup
		done.Add(2)
		errs := make([]error, 2)
		results := make([]*ClaimResult, 2)
		for i := 0; i < 2; i++ {
			go func(i int) {
				defer done.Done()
				<-start
				results[i], errs[i] = f.r.Claim(ctx, f.actors[0], f.request(i, "cross-batch-key"))
			}(i)
		}
		close(start)
		done.Wait()
		wins := 0
		for i, err := range errs {
			if err == nil {
				wins++
				f.success(i, results[i])
			} else if !errors.Is(err, ErrClaimConflict) {
				t.Fatal(err)
			}
		}
		if wins != 1 {
			t.Fatalf("winners=%d", wins)
		}
		f.equal("single reservation capacity delta", `SELECT CONCAT(reserved_kg,':',version) FROM recycler_capacity_pools WHERE id=?`, "200.00:8", f.pools[0])
	})
	t.Run("two_batches_compete_for_one_remaining_slot", func(t *testing.T) {
		f := fixture(t)
		f.exec(`UPDATE recycler_capacity_pools SET total_kg=200 WHERE id=?`, f.pools[0])
		start := make(chan struct{})
		var done sync.WaitGroup
		done.Add(2)
		errs := make([]error, 2)
		results := make([]*ClaimResult, 2)
		for i := 0; i < 2; i++ {
			go func(i int) {
				defer done.Done()
				<-start
				results[i], errs[i] = f.r.Claim(ctx, f.actors[0], f.request(i, fmt.Sprintf("pool-race-key-%d", i)))
			}(i)
		}
		close(start)
		done.Wait()
		wins := 0
		for i, err := range errs {
			if err == nil {
				wins++
				f.success(i, results[i])
			} else if !errors.Is(err, ErrClaimIneligible) {
				t.Fatal(err)
			}
		}
		if wins != 1 {
			t.Fatalf("winners=%d", wins)
		}
		f.equal("no oversubscription", `SELECT CONCAT(total_kg,':',reserved_kg,':',version) FROM recycler_capacity_pools WHERE id=?`, "200.00:200.00:8", f.pools[0])
	})

	for _, stage := range []string{"pool", "claim", "reservation", "batch", "audit", "outbox", "command", "before_commit"} {
		t.Run("rollback_after_"+stage, func(t *testing.T) {
			f := fixture(t)
			injected := errors.New("injected write failure")
			f.r.afterWrite = func(point string) error {
				if point == stage {
					return injected
				}
				return nil
			}
			before := claimSnapshot(t, db)
			result, err := f.r.Claim(ctx, f.actors[0], f.request(0, "rollback-key-001"))
			if result != nil || !errors.Is(err, injected) {
				t.Fatalf("fault not observed at %s: %v", stage, err)
			}
			f.unchanged(before)
		})
	}

	cases := []struct {
		name   string
		mutate func(*claimFixture, *ClaimRequest)
		want   error
	}{
		{"stale_version", func(f *claimFixture, r *ClaimRequest) { r.ExpectedVersion = 2 }, ErrClaimConflict},
		{"stale_epoch", func(f *claimFixture, r *ClaimRequest) { r.ClaimEpoch = "2" }, ErrClaimConflict},
		{"submitted", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE ewaste_batches SET status='SUBMITTED' WHERE id=?`, r.BatchID)
		}, ErrClaimNotReady},
		{"draft", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE ewaste_batches SET status='DRAFT',submitted_at=NULL WHERE id=?`, r.BatchID)
		}, ErrClaimNotReady},
		{"wrong_decision_version", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE matching_decisions SET batch_version=1 WHERE batch_id=?`, r.BatchID)
		}, ErrClaimIneligible},
		{"wrong_decision_epoch", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE matching_decisions SET claim_epoch=2 WHERE batch_id=?`, r.BatchID)
		}, ErrClaimIneligible},
		{"unmatched_org", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE matched_results SET zone_match=0,is_matched=0,reason_code='OUT_OF_SERVICE_ZONE',failed_rules_json='["M4"]' WHERE batch_id=? AND recycler_org_id=?`, r.BatchID, f.orgs[0])
		}, ErrClaimIneligible},
		{"live_capacity", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE recycler_capacity_pools SET reserved_kg=950 WHERE id=?`, f.pools[0])
		}, ErrClaimIneligible},
		{"live_pool_inactive", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE recycler_capacity_pools SET is_active=0 WHERE id=?`, f.pools[0])
		}, ErrClaimIneligible},
		{"live_profile", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE recycler_matching_profiles SET is_active=0 WHERE recycler_org_id=?`, f.orgs[0])
		}, ErrClaimIneligible},
		{"live_category", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE recycler_category_capabilities SET is_active=0 WHERE recycler_org_id=?`, f.orgs[0])
		}, ErrClaimIneligible},
		{"live_condition", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE recycler_category_capabilities SET accepted_conditions_json='["FUNCTIONAL"]' WHERE recycler_org_id=?`, f.orgs[0])
		}, ErrClaimIneligible},
		{"live_data_bearing", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE recycler_category_capabilities SET supports_data_bearing=0 WHERE recycler_org_id=?`, f.orgs[0])
		}, ErrClaimIneligible},
		{"live_zone", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE recycler_service_zones SET is_active=0 WHERE recycler_org_id=?`, f.orgs[0])
		}, ErrClaimIneligible},
		{"live_lead_time", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE recycler_service_zones SET minimum_lead_minutes=4294967295 WHERE recycler_org_id=?`, f.orgs[0])
		}, ErrClaimIneligible},
		{"deadline_passed", func(f *claimFixture, r *ClaimRequest) {
			f.r.now = func() time.Time { return claimFixtureTime.Add(8 * 24 * time.Hour) }
			f.exec(`UPDATE sessions SET expires_at=? WHERE session_id=?`, claimFixtureTime.Add(9*24*time.Hour), f.actors[0].SessionID)
		}, ErrClaimIneligible},
		{"wrong_role", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE users SET role_code='DONOR' WHERE user_id=?`, f.actors[0].UserID)
		}, ErrClaimForbidden},
		{"wrong_org_type", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE organisations SET organisation_type='DONOR' WHERE organisation_id=?`, f.orgs[0])
		}, ErrClaimForbidden},
		{"inactive_org", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE organisations SET status='SUSPENDED' WHERE organisation_id=?`, f.orgs[0])
		}, ErrClaimForbidden},
		{"inactive_user", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE users SET status='DISABLED' WHERE user_id=?`, f.actors[0].UserID)
		}, ErrClaimUnauthorized},
		{"expired_session", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE sessions SET expires_at=? WHERE session_id=?`, claimFixtureTime, f.actors[0].SessionID)
		}, ErrClaimUnauthorized},
		{"revoked_session", func(f *claimFixture, r *ClaimRequest) {
			f.exec(`UPDATE sessions SET revoked_at=? WHERE session_id=?`, claimFixtureTime, f.actors[0].SessionID)
		}, ErrClaimUnauthorized},
		{"wrong_session_owner", func(f *claimFixture, r *ClaimRequest) { f.actors[0].SessionID = f.actors[1].SessionID }, ErrClaimUnauthorized},
	}
	for _, tc := range cases {
		t.Run("reject_"+tc.name, func(t *testing.T) {
			f := fixture(t)
			req := f.request(0, "rejection-key-001")
			tc.mutate(f, &req)
			before := claimSnapshot(t, db)
			result, err := f.r.Claim(ctx, f.actors[0], req)
			if result != nil || !errors.Is(err, tc.want) {
				t.Fatalf("got %+v %v want %v", result, err, tc.want)
			}
			f.unchanged(before)
		})
	}

	t.Run("expired_advisory_lease_second_sql_entrant", func(t *testing.T) {
		f := fixture(t)
		locked := make(chan struct{})
		release := make(chan struct{})
		f.r.afterWrite = func(stage string) error {
			if stage == "batch_locked" {
				close(locked)
				<-release
			}
			return nil
		}
		other, _ := NewSQLClaimRepository(db, f.r.options)
		other.now = f.r.now
		var first, second *ClaimResult
		var e1, e2 error
		var done sync.WaitGroup
		done.Add(2)
		go func() { defer done.Done(); first, e1 = f.r.Claim(ctx, f.actors[0], f.request(0, "old-lease-key-001")) }()
		select {
		case <-locked:
		case <-time.After(5 * time.Second):
			t.Fatal("first transaction did not lock")
		}
		// Both lease holders deliberately enter SQL. A DB wait is observed rather
		// than depending on sleeps or a Redis timing assumption.
		go func() {
			defer done.Done()
			second, e2 = other.Claim(ctx, f.actors[1], f.request(0, "new-lease-key-002"))
		}()
		deadline := time.After(5 * time.Second)
		ticker := time.NewTicker(10 * time.Millisecond)
		defer ticker.Stop()
	waitLoop:
		for {
			select {
			case <-deadline:
				close(release)
				done.Wait()
				t.Fatal("no MySQL lock contention observed")
			case <-ticker.C:
				var waits int
				if err := db.QueryRow(`SELECT COUNT(*) FROM performance_schema.data_lock_waits`).Scan(&waits); err != nil {
					close(release)
					done.Wait()
					t.Fatal(err)
				}
				if waits > 0 {
					break waitLoop
				}
			}
		}
		close(release)
		done.Wait()
		if e1 != nil || first == nil || second != nil || !errors.Is(e2, ErrClaimConflict) {
			t.Fatalf("first=%v second=%v", e1, e2)
		}
		f.success(0, first)
		t.Log("two admitted lease holders, observed SQL lock wait, exactly one committed winner; Redis token cleanup is outside this test")
	})

	for _, errno := range []uint16{1213, 1205} {
		t.Run(fmt.Sprintf("whole_transaction_retry_%d", errno), func(t *testing.T) {
			f := fixture(t)
			calls := 0
			f.r.afterWrite = func(stage string) error {
				if stage == "outbox" {
					calls++
					if calls == 1 {
						return &mysql.MySQLError{Number: errno, Message: "injected transient database error"}
					}
				}
				return nil
			}
			result, err := f.r.Claim(ctx, f.actors[0], f.request(0, "transient-key-001"))
			if err != nil {
				t.Fatal(err)
			}
			if calls != 2 {
				t.Fatalf("attempts=%d", calls)
			}
			f.success(0, result)
			f.equal("one pool delta after retry", `SELECT CONCAT(reserved_kg,':',version) FROM recycler_capacity_pools WHERE id=?`, "200.00:8", f.pools[0])
		})
	}
	t.Run("bounded_retry_exhaustion", func(t *testing.T) {
		f := fixture(t)
		calls := 0
		f.r.afterWrite = func(stage string) error {
			if stage == "claim" {
				calls++
				return &mysql.MySQLError{Number: 1213}
			}
			return nil
		}
		before := claimSnapshot(t, db)
		result, err := f.r.Claim(ctx, f.actors[0], f.request(0, "bounded-key-001"))
		if result != nil || !errors.Is(err, ErrClaimRetryable) || calls != f.r.options.MaxAttempts {
			t.Fatalf("result=%v error=%v attempts=%d", result, err, calls)
		}
		f.unchanged(before)
	})
}
PERSISTENCE_EMBED_032

  mkdir -p "$WORK_DIR/backend/internal/repository"
  # Embedded backend/internal/repository/claim_test.go
  cat > "$WORK_DIR/backend/internal/repository/claim_test.go" <<'PERSISTENCE_EMBED_033'
package repository

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"
)

func validClaimRequest() ClaimRequest {
	return ClaimRequest{BatchID: "b3100000-0000-4000-8000-000000000001", ExpectedVersion: 3,
		ClaimEpoch: "1", IdempotencyKey: "C3-Unit-Key-00001", CorrelationID: "unit-correlation"}
}

func TestClaimCanonicalHash(t *testing.T) {
	a := claimIdentity{user: "USR-007", org: "PROC-001", scope: "user:USR-007"}
	r := validClaimRequest()
	actual, err := claimRequestHash(a, r)
	if err != nil {
		t.Fatal(err)
	}
	canonical := `{"actor_user_id":"USR-007","batch_id":"b3100000-0000-4000-8000-000000000001","claim_epoch":"1","expected_version":3,"notes":null,"recycler_org_id":"PROC-001"}`
	h := sha256.Sum256([]byte(canonical))
	expected := hex.EncodeToString(h[:])
	if actual != expected {
		t.Fatalf("hash=%s expected=%s", actual, expected)
	}
	r.CorrelationID = "another-correlation"
	r.IdempotencyKey = "Other-Exact-Key-01"
	transport, _ := claimRequestHash(a, r)
	if transport != actual {
		t.Fatal("transport entered hash")
	}
	empty := ""
	r.Notes = &empty
	changed, _ := claimRequestHash(a, r)
	if changed == actual {
		t.Fatal("omitted and empty notes must differ")
	}
	r.Notes = nil
	a.org = "PROC-002"
	changed, _ = claimRequestHash(a, r)
	if changed == actual {
		t.Fatal("organisation not covered by hash")
	}
}

func TestClaimInputBoundaries(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*ClaimRequest)
		valid  bool
	}{
		{"uppercase_uuid_canonicalized", func(r *ClaimRequest) { r.BatchID = strings.ToUpper(r.BatchID) }, true},
		{"uuid_v1", func(r *ClaimRequest) { r.BatchID = "b3100000-0000-1000-8000-000000000001" }, false},
		{"uuid_wrong_variant", func(r *ClaimRequest) { r.BatchID = "b3100000-0000-4000-0000-000000000001" }, false},
		{"uuid_noncanonical_form", func(r *ClaimRequest) { r.BatchID = strings.ReplaceAll(r.BatchID, "-", "") }, false},
		{"epoch_max", func(r *ClaimRequest) { r.ClaimEpoch = "18446744073709551615" }, true},
		{"epoch_overflow", func(r *ClaimRequest) { r.ClaimEpoch = "18446744073709551616" }, false},
		{"epoch_zero", func(r *ClaimRequest) { r.ClaimEpoch = "0" }, false},
		{"epoch_leading_zero", func(r *ClaimRequest) { r.ClaimEpoch = "01" }, false},
		{"epoch_plus", func(r *ClaimRequest) { r.ClaimEpoch = "+1" }, false},
		{"version_zero", func(r *ClaimRequest) { r.ExpectedVersion = 0 }, false},
		{"key_15", func(r *ClaimRequest) { r.IdempotencyKey = strings.Repeat("a", 15) }, false},
		{"key_64", func(r *ClaimRequest) { r.IdempotencyKey = strings.Repeat("a", 64) }, true},
		{"key_65", func(r *ClaimRequest) { r.IdempotencyKey = strings.Repeat("a", 65) }, false},
		{"key_non_ascii", func(r *ClaimRequest) { r.IdempotencyKey = strings.Repeat("界", 16) }, false},
		{"key_control", func(r *ClaimRequest) { r.IdempotencyKey = "C3-Key-000000000\n" }, false},
		{"key_spaces_preserved", func(r *ClaimRequest) { r.IdempotencyKey = "  C3-Key-000000000  " }, true},
		{"notes_255_unicode", func(r *ClaimRequest) { v := strings.Repeat("界", 255); r.Notes = &v }, true},
		{"notes_256_unicode", func(r *ClaimRequest) { v := strings.Repeat("界", 256); r.Notes = &v }, false},
		{"notes_invalid_utf8", func(r *ClaimRequest) { v := string([]byte{0xff}); r.Notes = &v }, false},
		{"correlation_empty", func(r *ClaimRequest) { r.CorrelationID = "" }, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := validClaimRequest()
			tc.mutate(&r)
			actual, err := canonicalClaimRequest(r)
			if tc.valid {
				if err != nil {
					t.Fatal(err)
				}
				if actual.IdempotencyKey != r.IdempotencyKey {
					t.Fatal("key bytes changed")
				}
				if actual.BatchID != strings.ToLower(r.BatchID) {
					t.Fatal("UUID not canonicalized")
				}
			} else if !errors.Is(err, ErrClaimInvalid) {
				t.Fatalf("got %v", err)
			}
		})
	}
}

func TestClaimRequiresExplicitOperationalSettings(t *testing.T) {
	if _, err := NewSQLClaimRepository(&sql.DB{}, ClaimPersistenceOptions{}); err == nil {
		t.Fatal("implicit defaults accepted")
	}
	opts := ClaimPersistenceOptions{RetainFor: time.Hour, TransactionTimeout: time.Second, MaxAttempts: 2, RetryBackoff: time.Millisecond}
	if _, err := NewSQLClaimRepository(nil, opts); err == nil {
		t.Fatal("nil database accepted")
	}
	if _, err := NewSQLClaimRepository(&sql.DB{}, opts); err != nil {
		t.Fatal(err)
	}
}
PERSISTENCE_EMBED_033

  mkdir -p "$WORK_DIR/backend/internal/router"
  # Embedded backend/internal/router/router_test.go
  cat > "$WORK_DIR/backend/internal/router/router_test.go" <<'PERSISTENCE_EMBED_034'
package router

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"

	"workflow-api/internal/controller"
	"workflow-api/internal/docs"
	"workflow-api/internal/health"
	"workflow-api/internal/model"
	"workflow-api/internal/repository"
	"workflow-api/internal/service"
	"workflow-api/internal/token"
)

type routerTestRepository struct{}

func (routerTestRepository) FindActiveUserByEmail(context.Context, string) (*model.User, error) {
	return nil, repository.ErrNotFound
}

func (routerTestRepository) FindActiveUserByID(context.Context, string) (*model.User, error) {
	return nil, repository.ErrNotFound
}

func (routerTestRepository) CreateLoginSession(context.Context, *model.User, *model.Session, time.Time) error {
	return nil
}

func (routerTestRepository) CreateLoginAudit(context.Context, *model.LoginAudit) error {
	return nil
}

func (routerTestRepository) FindSession(context.Context, string) (*model.Session, error) {
	return nil, repository.ErrNotFound
}

func (routerTestRepository) RotateSession(context.Context, string, string, string, string, time.Time, time.Time) error {
	return nil
}

func (routerTestRepository) RevokeSession(context.Context, string, string, string, time.Time) error {
	return nil
}

type routerTestLimiter struct{}

func (routerTestLimiter) Allow(context.Context, string) (bool, error) {
	return true, nil
}

func newRouterTest(t *testing.T, checker *health.Checker) *gin.Engine {
	t.Helper()
	repo := routerTestRepository{}
	tokens := token.NewService("router-test", "access-secret", "refresh-secret", "refresh-hash-secret", time.Minute, time.Hour)
	authService := service.NewAuthService(repo, tokens, zap.NewNop())
	authController := controller.NewAuthController(authService, zap.NewNop())
	return NewAuthRouter(authController, tokens, repo, routerTestLimiter{}, checker)
}

func TestNewTestRouterHelloEndpoint(t *testing.T) {
	r := NewTestRouter()
	res := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/hello", nil)
	req.Header.Set("Origin", "https://aca-ewaste-dev-ui.kindflower-300f4866.malaysiawest.azurecontainerapps.io")
	r.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", res.Code)
	}
	if got := res.Header().Get("Access-Control-Allow-Origin"); got != req.Header.Get("Origin") {
		t.Fatalf("expected CORS allow-origin %q, got %q", req.Header.Get("Origin"), got)
	}
}

func TestNewTestRouterNotFoundEndpoint(t *testing.T) {
	r := NewTestRouter()
	res := httptest.NewRecorder()
	r.ServeHTTP(res, httptest.NewRequest(http.MethodGet, "/missing", nil))
	if res.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", res.Code)
	}
}

func TestAuthRouterHealthEndpoints(t *testing.T) {
	checker := health.NewCheckerWithPingers(
		func(context.Context) error { return nil },
		func(context.Context) error { return nil },
		time.Second,
	)
	r := newRouterTest(t, checker)

	liveness := httptest.NewRecorder()
	r.ServeHTTP(liveness, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if liveness.Code != http.StatusOK {
		t.Fatalf("expected liveness 200, got %d", liveness.Code)
	}

	readiness := httptest.NewRecorder()
	r.ServeHTTP(readiness, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if readiness.Code != http.StatusOK {
		t.Fatalf("expected readiness 200, got %d", readiness.Code)
	}
	var report health.Report
	if err := json.Unmarshal(readiness.Body.Bytes(), &report); err != nil {
		t.Fatalf("decode readiness report: %v", err)
	}
	if report.Status != "ready" || report.MySQL != "ok" || report.Redis != "ok" {
		t.Fatalf("unexpected readiness report: %+v", report)
	}
}

func TestAuthRouterReadinessReturns503WhenDependencyFails(t *testing.T) {
	checker := health.NewCheckerWithPingers(
		func(context.Context) error { return errors.New("mysql unavailable") },
		func(context.Context) error { return nil },
		time.Second,
	)
	r := newRouterTest(t, checker)

	res := httptest.NewRecorder()
	r.ServeHTTP(res, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if res.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected readiness 503, got %d", res.Code)
	}
	var report health.Report
	if err := json.Unmarshal(res.Body.Bytes(), &report); err != nil {
		t.Fatalf("decode readiness failure report: %v", err)
	}
	if report.Status != "not_ready" || report.MySQL != "unavailable" || report.Redis != "ok" {
		t.Fatalf("unexpected readiness failure report: %+v", report)
	}
}

func TestDocsExposeOpenAPISpecAndSwaggerUI(t *testing.T) {
	r := NewTestRouter()
	docs.Register(r)

	spec := httptest.NewRecorder()
	r.ServeHTTP(spec, httptest.NewRequest(http.MethodGet, "/openapi.yaml", nil))
	if spec.Code != http.StatusOK {
		t.Fatalf("expected OpenAPI 200, got %d", spec.Code)
	}
	if spec.Header().Get("Content-Type") != "application/yaml; charset=utf-8" {
		t.Fatalf("unexpected OpenAPI content type: %q", spec.Header().Get("Content-Type"))
	}

	ui := httptest.NewRecorder()
	r.ServeHTTP(ui, httptest.NewRequest(http.MethodGet, "/docs/", nil))
	if ui.Code != http.StatusOK {
		t.Fatalf("expected Swagger UI 200, got %d", ui.Code)
	}
}
PERSISTENCE_EMBED_034

  mkdir -p "$WORK_DIR/backend/internal/service"
  # Embedded backend/internal/service/auth_test.go
  cat > "$WORK_DIR/backend/internal/service/auth_test.go" <<'PERSISTENCE_EMBED_035'
package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"go.uber.org/zap"
	"golang.org/x/crypto/bcrypt"

	"workflow-api/internal/dto"
	"workflow-api/internal/model"
	"workflow-api/internal/repository"
	"workflow-api/internal/token"
)

type fakeAuthRepository struct {
	user     *model.User
	session  *model.Session
	audits   []*model.LoginAudit
	auditErr error
}

func (f *fakeAuthRepository) FindActiveUserByEmail(context.Context, string) (*model.User, error) {
	if f.user == nil {
		return nil, repository.ErrNotFound
	}
	return f.user, nil
}

func (f *fakeAuthRepository) FindActiveUserByID(context.Context, string) (*model.User, error) {
	if f.user == nil || f.user.Status != "ACTIVE" {
		return nil, repository.ErrNotFound
	}
	return f.user, nil
}

func (f *fakeAuthRepository) CreateLoginSession(_ context.Context, _ *model.User, session *model.Session, _ time.Time) error {
	f.session = session
	return nil
}

func (f *fakeAuthRepository) CreateLoginAudit(_ context.Context, audit *model.LoginAudit) error {
	if f.auditErr != nil {
		return f.auditErr
	}
	f.audits = append(f.audits, audit)
	return nil
}

func (f *fakeAuthRepository) FindSession(context.Context, string) (*model.Session, error) {
	if f.session == nil {
		return nil, repository.ErrNotFound
	}
	return f.session, nil
}

func (f *fakeAuthRepository) RotateSession(_ context.Context, _, _, oldHash, newHash string, expiresAt, now time.Time) error {
	if f.session == nil || f.session.RefreshTokenHash != oldHash || f.session.Status != "ACTIVE" || !f.session.ExpiresAt.After(now) {
		return repository.ErrRotationRejected
	}
	f.session.RefreshTokenHash = newHash
	f.session.ExpiresAt = expiresAt
	f.session.LastSeenAt = &now
	return nil
}

func (f *fakeAuthRepository) RevokeSession(_ context.Context, _, _, _ string, _ time.Time) error {
	if f.session == nil {
		return repository.ErrNotFound
	}
	f.session.Status = "REVOKED"
	return nil
}

func TestLoginAndRefreshRotateTheSession(t *testing.T) {
	passwordHash, err := bcrypt.GenerateFromPassword([]byte("correct-password"), bcrypt.MinCost)
	if err != nil {
		t.Fatalf("hash password: %v", err)
	}
	repo := &fakeAuthRepository{user: &model.User{
		UserID: "USR-001", Email: "donor@example.com", PasswordHash: string(passwordHash),
		RoleCode: "DONOR", OrganisationID: "DON-001", Status: "ACTIVE",
	}}
	service := NewAuthService(repo, token.NewService("test", "access", "refresh", "hash", 15*time.Minute, 24*time.Hour), zap.NewNop())
	now := time.Now().UTC().Truncate(time.Second)
	service.clock = func() time.Time { return now }

	response, err := service.Login(context.Background(), dto.LoginRequest{Email: " DONOR@EXAMPLE.COM ", Password: "correct-password"}, LoginAuditMetadata{
		CorrelationID: "corr-login-001",
		SourceIP:      "192.0.2.10",
	})
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	if response.TokenType != "Bearer" || response.AccessToken == "" || response.RefreshToken == "" {
		t.Fatalf("unexpected login response: %+v", response)
	}
	if len(repo.audits) != 1 || repo.audits[0].Result != LoginAuditSuccess || repo.audits[0].AttemptedEmail != "donor@example.com" {
		t.Fatalf("unexpected successful login audit: %+v", repo.audits)
	}
	if repo.audits[0].UserID == nil || *repo.audits[0].UserID != "USR-001" || repo.audits[0].CorrelationID != "corr-login-001" {
		t.Fatalf("successful login audit missing identity: %+v", repo.audits[0])
	}
	oldHash := repo.session.RefreshTokenHash
	rotated, err := service.Refresh(context.Background(), response.RefreshToken)
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if rotated.RefreshToken == response.RefreshToken || repo.session.RefreshTokenHash == oldHash {
		t.Fatal("refresh token was not rotated")
	}
	if _, err := service.Refresh(context.Background(), response.RefreshToken); !errors.Is(err, ErrInvalidSession) {
		t.Fatalf("expected old refresh token to be rejected, got %v", err)
	}
}

func TestLoginUsesGenericInvalidCredentialsError(t *testing.T) {
	repo := &fakeAuthRepository{user: &model.User{UserID: "USR-001", Email: "user@example.com", PasswordHash: "not-a-valid-bcrypt-hash", Status: "ACTIVE"}}
	service := NewAuthService(repo, token.NewService("test", "access", "refresh", "hash", time.Minute, time.Hour), zap.NewNop())

	_, err := service.Login(context.Background(), dto.LoginRequest{Email: "user@example.com", Password: "wrong"}, LoginAuditMetadata{CorrelationID: "corr-failure-001"})
	if !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("expected generic invalid credentials error, got %v", err)
	}
	if len(repo.audits) != 1 || repo.audits[0].Result != LoginAuditFailure || repo.audits[0].ReasonCode == nil || *repo.audits[0].ReasonCode != "AUTH_INVALID_CREDENTIALS" {
		t.Fatalf("unexpected invalid-credentials audit: %+v", repo.audits)
	}
}
PERSISTENCE_EMBED_035

  mkdir -p "$WORK_DIR/backend/internal/service"
  # Embedded backend/internal/service/hash_seed_tmp_test.go
  cat > "$WORK_DIR/backend/internal/service/hash_seed_tmp_test.go" <<'PERSISTENCE_EMBED_036'
package service

import (
	"fmt"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestPrintSeedHashes(t *testing.T) {
	for i := 0; i < 9; i++ {
		hash, err := bcrypt.GenerateFromPassword([]byte("TestPassword123!"), bcrypt.DefaultCost)
		if err != nil {
			t.Fatal(err)
		}
		fmt.Println(string(hash))
	}
}
PERSISTENCE_EMBED_036

  mkdir -p "$WORK_DIR/backend/internal/storage"
  # Embedded backend/internal/storage/mysql_test.go
  cat > "$WORK_DIR/backend/internal/storage/mysql_test.go" <<'PERSISTENCE_EMBED_037'
package storage

import (
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	mysqlDriver "github.com/go-sql-driver/mysql"
	"gorm.io/driver/mysql"
	"gorm.io/gorm"

	"workflow-api/internal/config"
)

func TestBuildMySQLDSNSeparatesConnectionSettings(t *testing.T) {
	dsn := buildMySQLDSN(config.DatabaseConfig{
		Host: "mysql", Port: 3306, Name: "ewaste", User: "ewaste_app", Password: "secret",
	})

	for _, expected := range []string{
		"ewaste_app:secret@tcp(mysql:3306)/ewaste",
		"charset=utf8mb4",
		"parseTime=true",
		"tls=preferred",
	} {
		if !contains(dsn, expected) {
			t.Fatalf("expected DSN to contain %q, got %q", expected, dsn)
		}
	}
	parsed, err := mysqlDriver.ParseDSN(dsn)
	if err != nil {
		t.Fatalf("parse DSN: %v", err)
	}
	if parsed.Params["time_zone"] != "'+00:00'" {
		t.Fatalf("expected UTC session timezone, got %q", parsed.Params["time_zone"])
	}
	if !parsed.AllowNativePasswords {
		t.Fatal("expected native password authentication to be allowed")
	}
}

func contains(value, fragment string) bool {
	for i := 0; i+len(fragment) <= len(value); i++ {
		if value[i:i+len(fragment)] == fragment {
			return true
		}
	}
	return false
}

func TestPingMySQLUsesDatabaseConnection(t *testing.T) {
	sqlDB, mock, err := sqlmock.New(sqlmock.MonitorPingsOption(true))
	if err != nil {
		t.Fatalf("create SQL mock: %v", err)
	}
	t.Cleanup(func() {
		if err := sqlDB.Close(); err != nil {
			t.Errorf("close SQL mock: %v", err)
		}
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Errorf("check SQL expectations: %v", err)
		}
	})
	mock.ExpectPing()
	mock.ExpectClose()

	gormDB, err := gorm.Open(mysql.New(mysql.Config{
		Conn:                      sqlDB,
		SkipInitializeWithVersion: true,
	}), &gorm.Config{DisableAutomaticPing: true})
	if err != nil {
		t.Fatalf("open gorm DB: %v", err)
	}

	if err := PingMySQL(gormDB, time.Second); err != nil {
		t.Fatalf("ping failed: %v", err)
	}
}
PERSISTENCE_EMBED_037

  mkdir -p "$WORK_DIR/backend/internal/token"
  # Embedded backend/internal/token/jwt_test.go
  cat > "$WORK_DIR/backend/internal/token/jwt_test.go" <<'PERSISTENCE_EMBED_038'
package token

import (
	"testing"
	"time"
)

func TestIssueAndParseTokens(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	service := NewService("test-issuer", "access-secret", "refresh-secret", "hash-secret", 15*time.Minute, 24*time.Hour)

	access, refresh, accessExpiry, refreshExpiry, err := service.Issue("USR-001", "session-001", "AUDITOR", "PLATFORM", now)
	if err != nil {
		t.Fatalf("issue tokens: %v", err)
	}
	if access == refresh || access == "" || refresh == "" {
		t.Fatal("expected two different non-empty tokens")
	}
	if !accessExpiry.Equal(now.Add(15*time.Minute)) || !refreshExpiry.Equal(now.Add(24*time.Hour)) {
		t.Fatal("unexpected token expiry")
	}

	accessClaims, err := service.ParseAccess(access)
	if err != nil {
		t.Fatalf("parse access token: %v", err)
	}
	if accessClaims.UserID != "USR-001" || accessClaims.SessionID != "session-001" || accessClaims.TokenType != AccessType {
		t.Fatalf("unexpected access claims: %+v", accessClaims)
	}
	if _, err := service.ParseAccess(refresh); err == nil {
		t.Fatal("refresh token must not be accepted as an access token")
	}

	refreshClaims, err := service.ParseRefresh(refresh)
	if err != nil {
		t.Fatalf("parse refresh token: %v", err)
	}
	if refreshClaims.UserID != "USR-001" || refreshClaims.TokenType != RefreshType {
		t.Fatalf("unexpected refresh claims: %+v", refreshClaims)
	}
	if service.HashRefresh(refresh) == refresh {
		t.Fatal("raw refresh token must not equal its stored hash")
	}
}
PERSISTENCE_EMBED_038

  mkdir -p "$WORK_DIR/backend/internal/events/contracts"
  # Embedded backend/internal/events/contracts/CollectionCompleted.v1.schema.json
  cat > "$WORK_DIR/backend/internal/events/contracts/CollectionCompleted.v1.schema.json" <<'PERSISTENCE_EMBED_039'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:ewaste:events:CollectionCompleted:v1",
  "title": "CollectionCompleted event v1 — draft",
  "description": "Committed successful pickup: ASSIGNED to COLLECTED. Assignment COMPLETED does not mean batch COMPLETED. Historical scope comes from the immutable parent assignment. This draft reuses the unchanged eleven-field v1 business envelope. Cross-record semantics and database checks are application obligations.",
  "type": "object",
  "required": [
    "event_id",
    "event_type",
    "schema_version",
    "command_id",
    "batch_id",
    "batch_version",
    "claim_epoch",
    "sequence_in_command",
    "occurred_at",
    "correlation_id",
    "data"
  ],
  "properties": {
    "event_id": {
      "$ref": "#/$defs/uuidV4"
    },
    "event_type": {
      "const": "CollectionCompleted"
    },
    "schema_version": {
      "type": "integer",
      "const": 1
    },
    "command_id": {
      "$ref": "#/$defs/uuidV4"
    },
    "batch_id": {
      "$ref": "#/$defs/uuidV4"
    },
    "batch_version": {
      "$ref": "#/$defs/positiveUint32"
    },
    "claim_epoch": {
      "$ref": "#/$defs/positiveUint64String"
    },
    "sequence_in_command": {
      "$ref": "#/$defs/positiveUint32"
    },
    "occurred_at": {
      "$ref": "#/$defs/utcTimestamp"
    },
    "correlation_id": {
      "type": "string",
      "minLength": 1,
      "maxLength": 128
    },
    "data": {
      "type": "object",
      "required": [
        "assignment_id",
        "handoff_id",
        "collector_user_id",
        "collector_org_id",
        "collector_scope_id",
        "actual_item_count",
        "pickup_occurred_at",
        "verification_hash"
      ],
      "properties": {
        "assignment_id": {
          "$ref": "#/$defs/uuidV4"
        },
        "handoff_id": {
          "$ref": "#/$defs/uuidV4"
        },
        "collector_user_id": {
          "type": "string",
          "minLength": 1,
          "maxLength": 32,
          "pattern": "^[\\x20-\\x7E]+$(?![\\s\\S])",
          "description": "Existing canonical ASCII users.user_id or organisations.organisation_id; not assumed UUID."
        },
        "collector_org_id": {
          "type": "string",
          "minLength": 1,
          "maxLength": 32,
          "pattern": "^[\\x20-\\x7E]+$(?![\\s\\S])",
          "description": "Existing canonical ASCII users.user_id or organisations.organisation_id; not assumed UUID."
        },
        "collector_scope_id": {
          "$ref": "#/$defs/uuidV4"
        },
        "actual_item_count": {
          "type": "integer",
          "minimum": 1,
          "maximum": 100000
        },
        "pickup_occurred_at": {
          "$ref": "#/$defs/utcTimestamp"
        },
        "verification_hash": {
          "type": "string",
          "pattern": "^[0-9A-Fa-f]{64}$(?![\\s\\S])",
          "description": "Opaque persisted batch_handoffs.verification_hash reference. Do not publish underlying donor proof, personal data or credential material."
        }
      },
      "additionalProperties": true
    }
  },
  "additionalProperties": true,
  "$defs": {
    "uuidV4": {
      "type": "string",
      "format": "uuid",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$(?![\\s\\S])",
      "description": "Server-generated canonical lowercase UUIDv4."
    },
    "positiveUint32": {
      "type": "integer",
      "minimum": 1,
      "maximum": 4294967295
    },
    "positiveUint64String": {
      "type": "string",
      "pattern": "^(?:[1-9][0-9]{0,18}|1[0-7][0-9]{18}|18[0-3][0-9]{17}|184[0-3][0-9]{16}|1844[0-5][0-9]{15}|18446[0-6][0-9]{14}|184467[0-3][0-9]{13}|1844674[0-3][0-9]{12}|184467440[0-6][0-9]{10}|1844674407[0-2][0-9]{9}|18446744073[0-6][0-9]{8}|1844674407370[0-8][0-9]{6}|18446744073709[0-4][0-9]{5}|184467440737095[0-4][0-9]{4}|18446744073709550[0-9]{3}|18446744073709551[0-5][0-9]{2}|1844674407370955160[0-9]|1844674407370955161[0-4]|18446744073709551615)$(?![\\s\\S])",
      "description": "Canonical decimal string, inclusive range 1 through 18446744073709551615; no leading zeroes."
    },
    "utcTimestamp": {
      "type": "string",
      "format": "date-time",
      "pattern": "^[1-9][0-9]{3}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]\\.[0-9]{6}Z$(?![\\s\\S])",
      "description": "UTC RFC3339, exactly six fractional digits, Z; MySQL DATETIME-compatible year. Enable format validation for calendar correctness."
    }
  }
}
PERSISTENCE_EMBED_039

  mkdir -p "$WORK_DIR/backend/internal/events/contracts"
  # Embedded backend/internal/events/contracts/CollectionFailed.v1.schema.json
  cat > "$WORK_DIR/backend/internal/events/contracts/CollectionFailed.v1.schema.json" <<'PERSISTENCE_EMBED_040'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:ewaste:events:CollectionFailed:v1",
  "title": "CollectionFailed event v1 — draft",
  "description": "Committed failed pickup: ASSIGNED to FAILED_COLLECTION. A separate audit-only automatic recovery later returns to APPROVED. No successful collection count or proof is represented here. This draft reuses the unchanged eleven-field v1 business envelope. Cross-record semantics and database checks are application obligations.",
  "type": "object",
  "required": [
    "event_id",
    "event_type",
    "schema_version",
    "command_id",
    "batch_id",
    "batch_version",
    "claim_epoch",
    "sequence_in_command",
    "occurred_at",
    "correlation_id",
    "data"
  ],
  "properties": {
    "event_id": {
      "$ref": "#/$defs/uuidV4"
    },
    "event_type": {
      "const": "CollectionFailed"
    },
    "schema_version": {
      "type": "integer",
      "const": 1
    },
    "command_id": {
      "$ref": "#/$defs/uuidV4"
    },
    "batch_id": {
      "$ref": "#/$defs/uuidV4"
    },
    "batch_version": {
      "$ref": "#/$defs/positiveUint32"
    },
    "claim_epoch": {
      "$ref": "#/$defs/positiveUint64String"
    },
    "sequence_in_command": {
      "$ref": "#/$defs/positiveUint32"
    },
    "occurred_at": {
      "$ref": "#/$defs/utcTimestamp"
    },
    "correlation_id": {
      "type": "string",
      "minLength": 1,
      "maxLength": 128
    },
    "data": {
      "type": "object",
      "required": [
        "assignment_id",
        "handoff_id",
        "collector_user_id",
        "collector_org_id",
        "collector_scope_id",
        "pickup_occurred_at",
        "failure_reason"
      ],
      "properties": {
        "assignment_id": {
          "$ref": "#/$defs/uuidV4"
        },
        "handoff_id": {
          "$ref": "#/$defs/uuidV4"
        },
        "collector_user_id": {
          "type": "string",
          "minLength": 1,
          "maxLength": 32,
          "pattern": "^[\\x20-\\x7E]+$(?![\\s\\S])",
          "description": "Existing canonical ASCII users.user_id or organisations.organisation_id; not assumed UUID."
        },
        "collector_org_id": {
          "type": "string",
          "minLength": 1,
          "maxLength": 32,
          "pattern": "^[\\x20-\\x7E]+$(?![\\s\\S])",
          "description": "Existing canonical ASCII users.user_id or organisations.organisation_id; not assumed UUID."
        },
        "collector_scope_id": {
          "$ref": "#/$defs/uuidV4"
        },
        "pickup_occurred_at": {
          "$ref": "#/$defs/utcTimestamp"
        },
        "failure_reason": {
          "type": "string",
          "enum": [
            "DONOR_UNAVAILABLE",
            "INCORRECT_ITEMS",
            "ACCESS_DENIED",
            "DAMAGED_HAZARDOUS",
            "SAFETY_CANCEL"
          ]
        }
      },
      "additionalProperties": true
    }
  },
  "additionalProperties": true,
  "$defs": {
    "uuidV4": {
      "type": "string",
      "format": "uuid",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$(?![\\s\\S])",
      "description": "Server-generated canonical lowercase UUIDv4."
    },
    "positiveUint32": {
      "type": "integer",
      "minimum": 1,
      "maximum": 4294967295
    },
    "positiveUint64String": {
      "type": "string",
      "pattern": "^(?:[1-9][0-9]{0,18}|1[0-7][0-9]{18}|18[0-3][0-9]{17}|184[0-3][0-9]{16}|1844[0-5][0-9]{15}|18446[0-6][0-9]{14}|184467[0-3][0-9]{13}|1844674[0-3][0-9]{12}|184467440[0-6][0-9]{10}|1844674407[0-2][0-9]{9}|18446744073[0-6][0-9]{8}|1844674407370[0-8][0-9]{6}|18446744073709[0-4][0-9]{5}|184467440737095[0-4][0-9]{4}|18446744073709550[0-9]{3}|18446744073709551[0-5][0-9]{2}|1844674407370955160[0-9]|1844674407370955161[0-4]|18446744073709551615)$(?![\\s\\S])",
      "description": "Canonical decimal string, inclusive range 1 through 18446744073709551615; no leading zeroes."
    },
    "utcTimestamp": {
      "type": "string",
      "format": "date-time",
      "pattern": "^[1-9][0-9]{3}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]\\.[0-9]{6}Z$(?![\\s\\S])",
      "description": "UTC RFC3339, exactly six fractional digits, Z; MySQL DATETIME-compatible year. Enable format validation for calendar correctness."
    }
  }
}
PERSISTENCE_EMBED_040

  mkdir -p "$WORK_DIR/backend/internal/events/contracts"
  # Embedded backend/internal/events/contracts/CollectorAssigned.v1.schema.json
  cat > "$WORK_DIR/backend/internal/events/contracts/CollectorAssigned.v1.schema.json" <<'PERSISTENCE_EMBED_041'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:ewaste:events:CollectorAssigned:v1",
  "title": "CollectorAssigned event v1 — draft",
  "description": "Committed collector choice: APPROVED to ASSIGNED. A replacement has a fresh assignment ID, previous assignment, next sequence and a different collector, preserving the accepted claim and epoch. This draft reuses the unchanged eleven-field v1 business envelope. Cross-record semantics and database checks are application obligations.",
  "type": "object",
  "required": [
    "event_id",
    "event_type",
    "schema_version",
    "command_id",
    "batch_id",
    "batch_version",
    "claim_epoch",
    "sequence_in_command",
    "occurred_at",
    "correlation_id",
    "data"
  ],
  "properties": {
    "event_id": {
      "$ref": "#/$defs/uuidV4"
    },
    "event_type": {
      "const": "CollectorAssigned"
    },
    "schema_version": {
      "type": "integer",
      "const": 1
    },
    "command_id": {
      "$ref": "#/$defs/uuidV4"
    },
    "batch_id": {
      "$ref": "#/$defs/uuidV4"
    },
    "batch_version": {
      "$ref": "#/$defs/positiveUint32"
    },
    "claim_epoch": {
      "$ref": "#/$defs/positiveUint64String"
    },
    "sequence_in_command": {
      "$ref": "#/$defs/positiveUint32"
    },
    "occurred_at": {
      "$ref": "#/$defs/utcTimestamp"
    },
    "correlation_id": {
      "type": "string",
      "minLength": 1,
      "maxLength": 128
    },
    "data": {
      "type": "object",
      "required": [
        "claim_id",
        "assignment_id",
        "recycler_org_id",
        "collector_org_id",
        "collector_user_id",
        "collector_scope_id",
        "assigned_at",
        "assignment_sequence",
        "assignment_version",
        "previous_assignment_id"
      ],
      "properties": {
        "claim_id": {
          "$ref": "#/$defs/uuidV4"
        },
        "assignment_id": {
          "$ref": "#/$defs/uuidV4"
        },
        "recycler_org_id": {
          "type": "string",
          "minLength": 1,
          "maxLength": 32,
          "pattern": "^[\\x20-\\x7E]+$(?![\\s\\S])",
          "description": "Existing canonical ASCII users.user_id or organisations.organisation_id; not assumed UUID."
        },
        "collector_org_id": {
          "type": "string",
          "minLength": 1,
          "maxLength": 32,
          "pattern": "^[\\x20-\\x7E]+$(?![\\s\\S])",
          "description": "Existing canonical ASCII users.user_id or organisations.organisation_id; not assumed UUID."
        },
        "collector_user_id": {
          "type": "string",
          "minLength": 1,
          "maxLength": 32,
          "pattern": "^[\\x20-\\x7E]+$(?![\\s\\S])",
          "description": "Existing canonical ASCII users.user_id or organisations.organisation_id; not assumed UUID."
        },
        "collector_scope_id": {
          "$ref": "#/$defs/uuidV4"
        },
        "assigned_at": {
          "$ref": "#/$defs/utcTimestamp"
        },
        "assignment_sequence": {
          "$ref": "#/$defs/positiveUint64String"
        },
        "assignment_version": {
          "$ref": "#/$defs/positiveInt64String"
        },
        "previous_assignment_id": {
          "oneOf": [
            {
              "$ref": "#/$defs/uuidV4"
            },
            {
              "type": "null"
            }
          ]
        }
      },
      "additionalProperties": true
    }
  },
  "additionalProperties": true,
  "$defs": {
    "uuidV4": {
      "type": "string",
      "format": "uuid",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$(?![\\s\\S])",
      "description": "Server-generated canonical lowercase UUIDv4."
    },
    "positiveUint32": {
      "type": "integer",
      "minimum": 1,
      "maximum": 4294967295
    },
    "positiveUint64String": {
      "type": "string",
      "pattern": "^(?:[1-9][0-9]{0,18}|1[0-7][0-9]{18}|18[0-3][0-9]{17}|184[0-3][0-9]{16}|1844[0-5][0-9]{15}|18446[0-6][0-9]{14}|184467[0-3][0-9]{13}|1844674[0-3][0-9]{12}|184467440[0-6][0-9]{10}|1844674407[0-2][0-9]{9}|18446744073[0-6][0-9]{8}|1844674407370[0-8][0-9]{6}|18446744073709[0-4][0-9]{5}|184467440737095[0-4][0-9]{4}|18446744073709550[0-9]{3}|18446744073709551[0-5][0-9]{2}|1844674407370955160[0-9]|1844674407370955161[0-4]|18446744073709551615)$(?![\\s\\S])",
      "description": "Canonical decimal string, inclusive range 1 through 18446744073709551615; no leading zeroes."
    },
    "utcTimestamp": {
      "type": "string",
      "format": "date-time",
      "pattern": "^[1-9][0-9]{3}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]\\.[0-9]{6}Z$(?![\\s\\S])",
      "description": "UTC RFC3339, exactly six fractional digits, Z; MySQL DATETIME-compatible year. Enable format validation for calendar correctness."
    },
    "positiveInt64String": {
      "type": "string",
      "pattern": "^(?:[1-9][0-9]{0,17}|[1-8][0-9]{18}|9[0-1][0-9]{17}|92[0-1][0-9]{16}|922[0-2][0-9]{15}|9223[0-2][0-9]{14}|92233[0-6][0-9]{13}|922337[0-1][0-9]{12}|92233720[0-2][0-9]{10}|922337203[0-5][0-9]{9}|9223372036[0-7][0-9]{8}|92233720368[0-4][0-9]{7}|922337203685[0-3][0-9]{6}|9223372036854[0-6][0-9]{5}|92233720368547[0-6][0-9]{4}|922337203685477[0-4][0-9]{3}|9223372036854775[0-7][0-9]{2}|922337203685477580[0-6]|9223372036854775807)$(?![\\s\\S])",
      "description": "Canonical decimal string 1..9223372036854775807; positive signed MySQL BIGINT, no leading zeroes."
    }
  }
}
PERSISTENCE_EMBED_041

}

run_c1() {
  EVIDENCE_DIR="$RUN_DIR/sprint1-c1"
  CHANGELOG="tests/c1/changelog-c1.yaml"
  mkdir -p "$EVIDENCE_DIR"
  printf '\nRunning sprint1-c1 checks from the embedded tests.\n'
  printf 'test_name\tactual\texpected\n' > "$EVIDENCE_DIR/migration-checks.tsv"
  echo '[1/6] Verifying a clean migration with all synthetic seeds excluded.'
  lb c1_clean validate validate
  lb c1_clean update-sql update-sql
  lb c1_clean schema update
  check_scalar c1_clean schema_changes 'SELECT COUNT(*) FROM DATABASECHANGELOG' 10
  check_scalar c1_clean seed_excluded_users 'SELECT COUNT(*) FROM users' 0
  check_scalar c1_clean seed_excluded_batches 'SELECT COUNT(*) FROM ewaste_batches' 0
  lb c1_clean identity-seed update --context-filter=seed
  check_scalar c1_clean ordinary_seed_excludes_c1 'SELECT COUNT(*) FROM ewaste_batches' 0

  echo '[2/6] Upgrading Sprint 1 while preserving its rows and changelog records.'
  lb c1_upgrade baseline --changelog-file=tests/c1/changelog-sprint1.yaml update --context-filter=seed
  check_scalar c1_upgrade baseline_changes 'SELECT COUNT(*) FROM DATABASECHANGELOG' 8
  dump_rows c1_upgrade "$EVIDENCE_DIR/identity-before.sql" organisations roles users sessions login_audit
  mysql_query c1_upgrade -e 'SELECT ID, AUTHOR, FILENAME, MD5SUM, DATEEXECUTED FROM DATABASECHANGELOG ORDER BY ID' > "$EVIDENCE_DIR/baseline-before.tsv"
  lb c1_upgrade validate validate
  lb c1_upgrade update-sql update-sql --context-filter=seed
  lb c1_upgrade upgrade update --context-filter=seed
  check_scalar c1_upgrade upgraded_changes 'SELECT COUNT(*) FROM DATABASECHANGELOG' 13
  dump_rows c1_upgrade "$EVIDENCE_DIR/identity-after.sql" organisations roles users sessions login_audit
  diff -u "$EVIDENCE_DIR/identity-before.sql" "$EVIDENCE_DIR/identity-after.sql" > "$EVIDENCE_DIR/identity-diff.txt"
  mysql_query c1_upgrade -e "SELECT ID, AUTHOR, FILENAME, MD5SUM, DATEEXECUTED FROM DATABASECHANGELOG WHERE ID LIKE 'EW101-%' ORDER BY ID" > "$EVIDENCE_DIR/baseline-after.tsv"
  diff -u "$EVIDENCE_DIR/baseline-before.tsv" "$EVIDENCE_DIR/baseline-after.tsv" > "$EVIDENCE_DIR/baseline-diff.txt"

  echo '[3/6] Applying deterministic fixtures and proving repeat update is a no-op.'
  for db in c1_clean c1_upgrade; do
    mysql_query "$db" < database/tests/verify-ew101-c1.sql > "$EVIDENCE_DIR/$db-sprint1.tsv"
    awk -F '\t' 'NR > 1 && $2 != "PASS" { bad=1 } END { exit bad }' "$EVIDENCE_DIR/$db-sprint1.tsv"
    lb "$db" fixtures update --context-filter=seed,c1-fixtures
    check_scalar "$db" "${db}_fixture_changes" 'SELECT COUNT(*) FROM DATABASECHANGELOG' 14
    check_scalar "$db" "${db}_fixture_rows" 'SELECT COUNT(*) FROM ewaste_batches' 7
    dump_rows "$db" "$EVIDENCE_DIR/$db-before.sql" ewaste_batches command_idempotency batch_audit_events event_outbox DATABASECHANGELOG
    lb "$db" repeat update --context-filter=seed,c1-fixtures
    dump_rows "$db" "$EVIDENCE_DIR/$db-after.sql" ewaste_batches command_idempotency batch_audit_events event_outbox DATABASECHANGELOG
    diff -u "$EVIDENCE_DIR/$db-before.sql" "$EVIDENCE_DIR/$db-after.sql" > "$EVIDENCE_DIR/$db-repeat-diff.txt"
  done

  echo '[4/6] Restarting MySQL to verify committed fixture persistence.'
  "${COMPOSE[@]}" restart mysql > "$EVIDENCE_DIR/restart.log" 2>&1
  "${COMPOSE[@]}" up -d --wait --wait-timeout 180 mysql >> "$EVIDENCE_DIR/restart.log" 2>&1
  for db in c1_clean c1_upgrade; do
    dump_rows "$db" "$EVIDENCE_DIR/$db-restarted.sql" ewaste_batches command_idempotency batch_audit_events event_outbox DATABASECHANGELOG
    diff -u "$EVIDENCE_DIR/$db-after.sql" "$EVIDENCE_DIR/$db-restarted.sql" > "$EVIDENCE_DIR/$db-restart-diff.txt"
  done

  echo '[5/6] Checking schema, valid/rejected records and transaction boundaries.'
  for db in c1_clean c1_upgrade; do
    mysql_query "$db" < database/tests/c1/verify.sql > "$EVIDENCE_DIR/$db-checks.tsv" 2> "$EVIDENCE_DIR/$db-checks-errors.log" || {
      awk -F '\t' 'NR == 1 || $2 == "FAIL"' "$EVIDENCE_DIR/$db-checks.tsv" >&2
      cat "$EVIDENCE_DIR/$db-checks-errors.log" >&2
      exit 1
    }
    awk -F '\t' 'NR > 1 { count++ } END { printf "%d SQL checks passed.\n", count }' "$EVIDENCE_DIR/$db-checks.tsv"
    dump_rows "$db" "$EVIDENCE_DIR/$db-final.sql" ewaste_batches command_idempotency batch_audit_events event_outbox
  done
  diff -u "$EVIDENCE_DIR/c1_clean-final.sql" "$EVIDENCE_DIR/c1_upgrade-final.sql" > "$EVIDENCE_DIR/clean-upgrade-diff.txt"

  echo '[6/6] All migration, persistence and rejection checks passed.'
  printf 'PASS\n' > "$EVIDENCE_DIR/result.txt"
  printf 'sprint1-c1\tPASS\t%s\n' "$EVIDENCE_DIR" >> "$RUN_DIR/summary.tsv"
}

run_c3() {
  EVIDENCE_DIR="$RUN_DIR/c2-c3"
  CHANGELOG="tests/c3/changelog-c3.yaml"
  mkdir -p "$EVIDENCE_DIR"
  printf '\nRunning c2-c3 checks from the embedded tests.\n'
  printf 'test_name\tactual\texpected\n' > "$EVIDENCE_DIR/migration-checks.tsv"
  echo '[1/6] Verifying clean C3 migrations.'
  lb c3_clean validate validate
  lb c3_clean preview update-sql
  lb c3_clean schema update
  check_scalar c3_clean schema_changes 'SELECT COUNT(*) FROM DATABASECHANGELOG' 21
  check_scalar c3_clean seed_excluded 'SELECT COUNT(*) FROM users' 0
  check_scalar c3_clean claims_empty 'SELECT COUNT(*) FROM batch_claims' 0
  lb c3_clean identities update --context-filter=seed
  check_scalar c3_clean c1_fixtures_opt_in 'SELECT COUNT(*) FROM ewaste_batches' 0

  echo '[2/6] Upgrading existing C1 fixtures while preserving all rows and changelog identities.'
  lb c3_upgrade c1-baseline --changelog-file=tests/c1/changelog-c1.yaml update --context-filter=seed,c1-fixtures
  check_scalar c3_upgrade c1_baseline_changes 'SELECT COUNT(*) FROM DATABASECHANGELOG' 14
  C1_TABLES=(organisations roles users sessions login_audit ewaste_batches command_idempotency batch_audit_events event_outbox)
  dump_rows c3_upgrade "$EVIDENCE_DIR/c1-before.sql" "${C1_TABLES[@]}"
  mysql_query c3_upgrade -e 'SELECT ID,AUTHOR,FILENAME,MD5SUM,DATEEXECUTED FROM DATABASECHANGELOG ORDER BY ID' > "$EVIDENCE_DIR/changelog-before.tsv"
  lb c3_upgrade validate validate
  lb c3_upgrade preview update-sql --context-filter=seed,c1-fixtures
  lb c3_upgrade upgrade update --context-filter=seed,c1-fixtures
  check_scalar c3_upgrade upgraded_changes 'SELECT COUNT(*) FROM DATABASECHANGELOG' 25
  dump_rows c3_upgrade "$EVIDENCE_DIR/c1-after.sql" "${C1_TABLES[@]}"
  diff -u "$EVIDENCE_DIR/c1-before.sql" "$EVIDENCE_DIR/c1-after.sql" > "$EVIDENCE_DIR/c1-preserved-diff.txt"
  mysql_query c3_upgrade -e "SELECT ID,AUTHOR,FILENAME,MD5SUM,DATEEXECUTED FROM DATABASECHANGELOG WHERE ID NOT LIKE 'EWCSB2-%' AND ID NOT LIKE 'EWCSB3-%' ORDER BY ID" > "$EVIDENCE_DIR/changelog-after.tsv"
  diff -u "$EVIDENCE_DIR/changelog-before.tsv" "$EVIDENCE_DIR/changelog-after.tsv" > "$EVIDENCE_DIR/changelog-preserved-diff.txt"

  echo '[3/6] Checking valid/rejected records, unique keys and foreign keys on both paths.'
  for db in c3_clean c3_upgrade; do
    mysql_query "$db" < database/tests/c3/schema-fixtures.sql
    mysql_query "$db" < database/tests/c3/verify-schema.sql > "$EVIDENCE_DIR/$db-schema.tsv" 2> "$EVIDENCE_DIR/$db-schema-errors.txt" || {
      awk -F '\t' 'NR==1 || $2=="FAIL"' "$EVIDENCE_DIR/$db-schema.tsv" >&2
      cat "$EVIDENCE_DIR/$db-schema-errors.txt" >&2; exit 1;
    }
    awk -F '\t' 'NR>1 {n++} END {printf "%d SQL schema checks passed.\n",n}' "$EVIDENCE_DIR/$db-schema.tsv"
  done

  echo '[4/6] Running Go tests with race detection, including real-MySQL claim concurrency.'
  run_go_tests 3

  echo '[5/6] Reapplying migrations and restarting MySQL with committed claim history.'
  DOMAIN_TABLES=("${C1_TABLES[@]}" matching_rule_sets recycler_matching_profiles recycler_capacity_pools recycler_category_capabilities recycler_service_zones matching_decisions matched_results batch_claims capacity_reservations DATABASECHANGELOG)
  for db in c3_clean c3_upgrade; do
    dump_rows "$db" "$EVIDENCE_DIR/$db-before-repeat.sql" "${DOMAIN_TABLES[@]}"
    if [[ "$db" == c3_clean ]]; then lb "$db" repeat update --context-filter=seed; else lb "$db" repeat update --context-filter=seed,c1-fixtures; fi
    dump_rows "$db" "$EVIDENCE_DIR/$db-after-repeat.sql" "${DOMAIN_TABLES[@]}"
    diff -u "$EVIDENCE_DIR/$db-before-repeat.sql" "$EVIDENCE_DIR/$db-after-repeat.sql" > "$EVIDENCE_DIR/$db-repeat-diff.txt"
  done
  "${COMPOSE[@]}" restart mysql > "$EVIDENCE_DIR/restart.txt" 2>&1
  "${COMPOSE[@]}" up -d --wait --wait-timeout 180 mysql >> "$EVIDENCE_DIR/restart.txt" 2>&1
  for db in c3_clean c3_upgrade; do
    dump_rows "$db" "$EVIDENCE_DIR/$db-after-restart.sql" "${DOMAIN_TABLES[@]}"
    diff -u "$EVIDENCE_DIR/$db-after-repeat.sql" "$EVIDENCE_DIR/$db-after-restart.sql" > "$EVIDENCE_DIR/$db-restart-diff.txt"
  done

  echo '[6/6] All C3 migration, schema and repository persistence checks passed.'
  printf 'PASS\n' > "$EVIDENCE_DIR/result.txt"
  printf 'c2-c3\tPASS\t%s\n' "$EVIDENCE_DIR" >> "$RUN_DIR/summary.tsv"
}

run_c4() {
  EVIDENCE_DIR="$RUN_DIR/c4"
  CHANGELOG="changelog-master.yaml"
  mkdir -p "$EVIDENCE_DIR"
  printf '\nRunning c4 checks from the embedded tests.\n'
  printf 'test_name\tactual\texpected\n' > "$EVIDENCE_DIR/migration-checks.tsv"
  echo '[1/6] Verifying clean C4 migrations.'
  lb c4_clean validate validate
  lb c4_clean preview update-sql
  lb c4_clean schema update
  check_scalar c4_clean schema_changes 'SELECT COUNT(*) FROM DATABASECHANGELOG' 28
  check_scalar c4_clean seed_excluded 'SELECT COUNT(*) FROM users' 0
  check_scalar c4_clean claims_empty 'SELECT COUNT(*) FROM batch_claims' 0
  lb c4_clean identities update --context-filter=seed
  check_scalar c4_clean c1_fixtures_opt_in 'SELECT COUNT(*) FROM ewaste_batches' 0

  echo '[2/6] Upgrading existing C3 claims while preserving all rows and changelog identities.'
  lb c4_upgrade c3-baseline --changelog-file=tests/c3/changelog-c3.yaml update --context-filter=seed,c1-fixtures
  check_scalar c4_upgrade c3_baseline_changes 'SELECT COUNT(*) FROM DATABASECHANGELOG' 25
  mysql_query c4_upgrade < database/tests/c3/schema-fixtures.sql
  C3_TABLES=(organisations roles users sessions login_audit ewaste_batches command_idempotency batch_audit_events event_outbox matching_rule_sets recycler_matching_profiles recycler_capacity_pools recycler_category_capabilities recycler_service_zones matching_decisions matched_results batch_claims capacity_reservations)
  dump_rows c4_upgrade "$EVIDENCE_DIR/c3-before.sql" "${C3_TABLES[@]}"
  mysql_query c4_upgrade -e 'SELECT ID,AUTHOR,FILENAME,MD5SUM,DATEEXECUTED FROM DATABASECHANGELOG ORDER BY ID' > "$EVIDENCE_DIR/changelog-before.tsv"
  lb c4_upgrade validate validate
  lb c4_upgrade preview update-sql --context-filter=seed,c1-fixtures
  lb c4_upgrade upgrade update --context-filter=seed,c1-fixtures
  check_scalar c4_upgrade upgraded_changes 'SELECT COUNT(*) FROM DATABASECHANGELOG' 32
  dump_rows c4_upgrade "$EVIDENCE_DIR/c3-after.sql" "${C3_TABLES[@]}"
  diff -u "$EVIDENCE_DIR/c3-before.sql" "$EVIDENCE_DIR/c3-after.sql" > "$EVIDENCE_DIR/c3-preserved-diff.txt"
  mysql_query c4_upgrade -e "SELECT ID,AUTHOR,FILENAME,MD5SUM,DATEEXECUTED FROM DATABASECHANGELOG WHERE ID NOT LIKE 'EWCSB4-%' ORDER BY ID" > "$EVIDENCE_DIR/changelog-after.tsv"
  diff -u "$EVIDENCE_DIR/changelog-before.tsv" "$EVIDENCE_DIR/changelog-after.tsv" > "$EVIDENCE_DIR/changelog-preserved-diff.txt"
  mysql_query c4_clean < database/tests/c3/schema-fixtures.sql

  echo '[3/6] Checking valid/rejected records, unique keys and foreign keys on both paths.'
  for db in c4_clean c4_upgrade; do
    mysql_query "$db" < database/tests/c4/schema-fixtures.sql
    mysql_query "$db" < database/tests/c4/verify-schema.sql > "$EVIDENCE_DIR/$db-schema.tsv" 2> "$EVIDENCE_DIR/$db-schema-errors.txt" || {
      awk -F '\t' 'NR==1 || $2=="FAIL"' "$EVIDENCE_DIR/$db-schema.tsv" >&2
      cat "$EVIDENCE_DIR/$db-schema-errors.txt" >&2; exit 1;
    }
    awk -F '\t' 'NR>1 {n++} END {printf "%d SQL schema checks passed.\n",n}' "$EVIDENCE_DIR/$db-schema.tsv"
  done

  echo '[4/6] Running Go tests with race detection, including real-MySQL assignment concurrency.'
  run_go_tests 4

  # Export the deterministic end-to-end lifecycle, including exact persisted envelopes.
  mysql_query c4_clean -e "SELECT * FROM batch_assignments WHERE batch_id='b4b00001-0000-4000-8000-000000000000' ORDER BY assignment_sequence" > "$EVIDENCE_DIR/lifecycle-assignments.tsv"
  mysql_query c4_clean -e "SELECT * FROM batch_handoffs WHERE batch_id='b4b00001-0000-4000-8000-000000000000' ORDER BY recorded_at,id" > "$EVIDENCE_DIR/lifecycle-handoffs.tsv"
  mysql_query c4_clean -e "SELECT * FROM batch_audit_events WHERE batch_id='b4b00001-0000-4000-8000-000000000000' ORDER BY batch_version" > "$EVIDENCE_DIR/lifecycle-audits.tsv"
  mysql_query c4_clean -e "SELECT * FROM event_outbox WHERE batch_id='b4b00001-0000-4000-8000-000000000000' ORDER BY aggregate_version" > "$EVIDENCE_DIR/lifecycle-outbox.tsv"

  echo '[5/6] Reapplying migrations and restarting MySQL with committed assignment history.'
  DOMAIN_TABLES=("${C3_TABLES[@]}" recycler_collector_scopes batch_assignments batch_handoffs assignment_actions DATABASECHANGELOG)
  for db in c4_clean c4_upgrade; do
    dump_rows "$db" "$EVIDENCE_DIR/$db-before-repeat.sql" "${DOMAIN_TABLES[@]}"
    if [[ "$db" == c4_clean ]]; then lb "$db" repeat update --context-filter=seed; else lb "$db" repeat update --context-filter=seed,c1-fixtures; fi
    dump_rows "$db" "$EVIDENCE_DIR/$db-after-repeat.sql" "${DOMAIN_TABLES[@]}"
    diff -u "$EVIDENCE_DIR/$db-before-repeat.sql" "$EVIDENCE_DIR/$db-after-repeat.sql" > "$EVIDENCE_DIR/$db-repeat-diff.txt"
  done
  "${COMPOSE[@]}" restart mysql > "$EVIDENCE_DIR/restart.txt" 2>&1
  "${COMPOSE[@]}" up -d --wait --wait-timeout 180 mysql >> "$EVIDENCE_DIR/restart.txt" 2>&1
  for db in c4_clean c4_upgrade; do
    dump_rows "$db" "$EVIDENCE_DIR/$db-after-restart.sql" "${DOMAIN_TABLES[@]}"
    diff -u "$EVIDENCE_DIR/$db-after-repeat.sql" "$EVIDENCE_DIR/$db-after-restart.sql" > "$EVIDENCE_DIR/$db-restart-diff.txt"
  done

  echo '[6/6] All C4 migration, schema and repository persistence checks passed.'
  printf 'PASS\n' > "$EVIDENCE_DIR/result.txt"
  printf 'c4\tPASS\t%s\n' "$EVIDENCE_DIR" >> "$RUN_DIR/summary.tsv"
}

main() {
  write_embedded_tests
  cd "$WORK_DIR"
  "${HASH[@]}" -c approved-migrations.sha256 > "$RUN_DIR/approved-migrations.txt"
  printf 'suite\tresult\tevidence_directory\n' > "$RUN_DIR/summary.tsv"
  echo 'Starting one isolated MySQL instance for all schema boundaries.'
  "${COMPOSE[@]}" build liquibase > "$RUN_DIR/build.log" 2>&1 || { cat "$RUN_DIR/build.log" >&2; return 1; }
  DOCKER_STARTED=1
  "${COMPOSE[@]}" up -d --wait --wait-timeout 180 mysql > "$RUN_DIR/startup.log" 2>&1 || { cat "$RUN_DIR/startup.log" >&2; return 1; }
  "${COMPOSE[@]}" exec -T -e MYSQL_PWD=persistence-root-test-only mysql mysql -uroot <<'PERSISTENCE_DATABASES'
CREATE DATABASE c1_upgrade CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE c3_clean CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE c3_upgrade CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE c4_clean CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE c4_upgrade CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
GRANT ALL ON c1_upgrade.* TO 'persistence_test'@'%';
GRANT ALL ON c3_clean.* TO 'persistence_test'@'%';
GRANT ALL ON c3_upgrade.* TO 'persistence_test'@'%';
GRANT ALL ON c4_clean.* TO 'persistence_test'@'%';
GRANT ALL ON c4_upgrade.* TO 'persistence_test'@'%';
GRANT SELECT ON performance_schema.data_lock_waits TO 'persistence_test'@'%';
PERSISTENCE_DATABASES
  mysql_query c1_clean -e 'SELECT VERSION() AS mysql_version, @@sql_mode AS sql_mode, @@global.time_zone AS global_time_zone;' > "$RUN_DIR/runtime.tsv"
  "${COMPOSE[@]}" run --rm -T liquibase --version > "$RUN_DIR/liquibase-version.txt" 2>&1
  run_c1
  run_c3
  run_c4
  cat "$RUN_DIR/summary.tsv"
  echo 'All embedded schema, migration and repository persistence checks passed.'
}
main "$@"
