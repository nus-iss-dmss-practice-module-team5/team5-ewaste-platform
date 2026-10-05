-- Sprint 3 Processing Migrations (026-030) Verification Suite
-- Evaluates schema presence, constraints, foreign keys, and indexes.
-- The test runner treats any row where result = 'FAIL' as a failure.

SELECT test_name, result, actual, expected
FROM (
    -- 1. Table Existence Checks
    SELECT
        'schema.batch_evidence_table' AS test_name,
        IF(COUNT(*) = 1, 'PASS', 'FAIL') AS result,
        CAST(COUNT(*) AS CHAR) AS actual,
        '1' AS expected
    FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = 'batch_evidence'

    UNION ALL

    SELECT
        'schema.batch_receipts_table',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = 'batch_receipts'

    UNION ALL

    SELECT
        'schema.batch_treatments_table',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = 'batch_treatments'

    UNION ALL

    SELECT
        'schema.batch_impact_metrics_table',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = 'batch_impact_metrics'

    UNION ALL

    SELECT
        'schema.batch_anomalies_table',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = 'batch_anomalies'

    -- 2. Foreign Key Parentage Checks
    UNION ALL

    SELECT
        'fk.evidence_to_batches',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.referential_constraints
    WHERE constraint_schema = DATABASE()
      AND table_name = 'batch_evidence'
      AND referenced_table_name = 'ewaste_batches'

    UNION ALL

    SELECT
        'fk.receipts_to_batches',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.referential_constraints
    WHERE constraint_schema = DATABASE()
      AND table_name = 'batch_receipts'
      AND referenced_table_name = 'ewaste_batches'

    UNION ALL

    SELECT
        'fk.treatments_to_batches',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.referential_constraints
    WHERE constraint_schema = DATABASE()
      AND table_name = 'batch_treatments'
      AND referenced_table_name = 'ewaste_batches'

    UNION ALL

    SELECT
        'fk.impact_metrics_to_batches',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.referential_constraints
    WHERE constraint_schema = DATABASE()
      AND table_name = 'batch_impact_metrics'
      AND referenced_table_name = 'ewaste_batches'

    UNION ALL

    SELECT
        'fk.anomalies_to_batches',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.referential_constraints
    WHERE constraint_schema = DATABASE()
      AND table_name = 'batch_anomalies'
      AND referenced_table_name = 'ewaste_batches'

    -- 3. Uniqueness Checks (1:1 semantics per batch for receipts, treatments, impact)
    UNION ALL

    SELECT
        'uniqueness.receipts_batch_id',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.table_constraints
    WHERE table_schema = DATABASE()
      AND table_name = 'batch_receipts'
      AND constraint_type = 'UNIQUE'

    UNION ALL

    SELECT
        'uniqueness.treatments_batch_id',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.table_constraints
    WHERE table_schema = DATABASE()
      AND table_name = 'batch_treatments'
      AND constraint_type = 'UNIQUE'

    UNION ALL

    SELECT
        'uniqueness.impact_metrics_batch_id',
        IF(COUNT(*) = 1, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '1'
    FROM information_schema.table_constraints
    WHERE table_schema = DATABASE()
      AND table_name = 'batch_impact_metrics'
      AND constraint_type = 'UNIQUE'

    -- 4. Liquibase Execution Record Count for Sprint 3
    UNION ALL

    SELECT
        'liquibase.s3_changesets_executed',
        IF(COUNT(*) = 5, 'PASS', 'FAIL'),
        CAST(COUNT(*) AS CHAR),
        '5'
    FROM DATABASECHANGELOG
    WHERE ID IN (
        'EWCSB3-026',
        'EWCSB3-027',
        'EWCSB3-028',
        'EWCSB3-029',
        'EWCSB3-030'
    )
) AS verification_results
ORDER BY test_name ASC;
