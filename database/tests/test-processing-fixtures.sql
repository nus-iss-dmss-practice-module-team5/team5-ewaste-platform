-- Sprint 3 Processing Fixtures Test Script
-- Demonstrates repeatable valid insertions and negative constraint enforcement.
-- Wrap in a transaction or execute cleanup at the end to ensure zero test residue.

START TRANSACTION;

-- ============================================================================
-- SCENARIO 1: Setup Isolated Test Batch (COLLECTED status)
-- ============================================================================
INSERT INTO ewaste_batches (
    id,
    organization_id,
    created_by,
    status,
    category,
    quantity,
    estimated_weight_kg,
    condition_rating,
    is_data_bearing,
    zone,
    notes,
    claim_epoch,
    version,
    submitted_at,
    created_at,
    updated_at
) VALUES (
    'b0000000-0000-4000-9999-000000000001',
    'org-enterprise-corp',
    'usr-alice-admin',
    'COLLECTED',
    'LARGE_APPLIANCE',
    10,
    250.00,
    'SCRAP',
    FALSE,
    'WEST',
    'Fixture batch for Sprint 3 processing verification tests',
    1,
    1,
    NOW(6),
    NOW(6),
    NOW(6)
);

-- ============================================================================
-- SCENARIO 2: Valid Evidence Attachments (Decision D2)
-- ============================================================================
-- 2.1 PDF Weighbridge Ticket (Receipt Stage)
INSERT INTO batch_evidence (
    evidence_id,
    batch_id,
    organisation_id,
    uploaded_by,
    lifecycle_stage,
    original_file_name,
    stored_object_key,
    mime_type,
    file_size_bytes,
    sha256_hash,
    created_at
) VALUES (
    'ev000000-0000-4000-8000-000000000001',
    'b0000000-0000-4000-9999-000000000001',
    'org-green-recycle',
    'usr-carol-recycler',
    'RECEIPT',
    'weighbridge_slip_20261005.pdf',
    'receipts/b0000000-0000-4000-9999-000000000001/ev000000-0000-4000-8000-000000000001.pdf',
    'application/pdf',
    245760,
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    NOW(6)
);

-- 2.2 JPEG Photo (Treatment Stage)
INSERT INTO batch_evidence (
    evidence_id,
    batch_id,
    organisation_id,
    uploaded_by,
    lifecycle_stage,
    original_file_name,
    stored_object_key,
    mime_type,
    file_size_bytes,
    sha256_hash,
    created_at
) VALUES (
    'ev000000-0000-4000-8000-000000000002',
    'b0000000-0000-4000-9999-000000000001',
    'org-green-recycle',
    'usr-carol-recycler',
    'TREATMENT',
    'de-manufacturing_photos.jpg',
    'treatment/b0000000-0000-4000-9999-000000000001/ev000000-0000-4000-8000-000000000002.jpg',
    'image/jpeg',
    1843200,
    '1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b',
    NOW(6)
);

-- ============================================================================
-- SCENARIO 3: Valid Receipt Verification Record
-- ============================================================================
INSERT INTO batch_receipts (
    receipt_id,
    batch_id,
    facility_org_id,
    verified_by,
    actual_category,
    actual_item_count,
    actual_weight_kg,
    condition_assessment,
    notes,
    verified_at,
    created_at
) VALUES (
    'rc000000-0000-4000-8000-000000000001',
    'b0000000-0000-4000-9999-000000000001',
    'org-green-recycle',
    'usr-carol-recycler',
    'LARGE_APPLIANCE',
    10,
    248.50,
    'DEFECTIVE',
    'Received 10 industrial washing machine units, average 24.85kg per unit',
    NOW(6),
    NOW(6)
);

-- Update batch status to VERIFIED
UPDATE ewaste_batches
SET status = 'VERIFIED', updated_at = NOW(6)
WHERE id = 'b0000000-0000-4000-9999-000000000001';

-- ============================================================================
-- SCENARIO 4: Valid Treatment Outcome (Decision D1 - Partial Breakdown)
-- ============================================================================
INSERT INTO batch_treatments (
    treatment_id,
    batch_id,
    facility_org_id,
    treated_by,
    reused_kg,
    recycled_kg,
    disposed_kg,
    unknown_kg,
    treatment_method,
    completed_at,
    created_at
) VALUES (
    'tr000000-0000-4000-8000-000000000001',
    'b0000000-0000-4000-9999-000000000001',
    'org-green-recycle',
    'usr-carol-recycler',
    25.00,
    180.00,
    30.00,
    13.50,
    'MECHANICAL_SHREDDING_AND_SORTING',
    NOW(6),
    NOW(6)
);

-- Update batch status to RECYCLED
UPDATE ewaste_batches
SET status = 'RECYCLED', updated_at = NOW(6)
WHERE id = 'b0000000-0000-4000-9999-000000000001';

-- ============================================================================
-- SCENARIO 5: Valid Impact Metrics (Decision D1 & EWCSB-159)
-- ============================================================================
INSERT INTO batch_impact_metrics (
    metric_id,
    batch_id,
    diverted_kg,
    unknown_kg,
    data_quality,
    rule_version,
    calculated_at,
    created_at
) VALUES (
    'im000000-0000-4000-8000-000000000001',
    'b0000000-0000-4000-9999-000000000001',
    205.00, -- 25.00 reused + 180.00 recycled
    13.50,
    'VERIFIED_COMPLETE',
    'v1.0.0-20261005',
    NOW(6),
    NOW(6)
);

-- Update batch status to COMPLETED
UPDATE ewaste_batches
SET status = 'COMPLETED', updated_at = NOW(6)
WHERE id = 'b0000000-0000-4000-9999-000000000001';

-- ============================================================================
-- SCENARIO 6: Valid Anomaly Records (EWCSB-159 & EWCSB-160)
-- ============================================================================
INSERT INTO batch_anomalies (
    anomaly_id,
    batch_id,
    anomaly_code,
    declared_value,
    actual_value,
    discrepancy_delta,
    rule_version,
    detected_at,
    created_at
) VALUES (
    'an000000-0000-4000-8000-000000000001',
    'b0000000-0000-4000-9999-000000000001',
    'WEIGHT_MISMATCH',
    '250.00',
    '248.50',
    -1.50,
    'v1.0.0-20261005',
    NOW(6),
    NOW(6)
);

-- ============================================================================
-- SCENARIO 7: Assertions on Inserted Test Data
-- ============================================================================
SELECT
    'test.fixture_pipeline_success' AS test_name,
    IF(
        (SELECT COUNT(*) FROM batch_evidence WHERE batch_id = 'b0000000-0000-4000-9999-000000000001') = 2 AND
        (SELECT COUNT(*) FROM batch_receipts WHERE batch_id = 'b0000000-0000-4000-9999-000000000001') = 1 AND
        (SELECT COUNT(*) FROM batch_treatments WHERE batch_id = 'b0000000-0000-4000-9999-000000000001') = 1 AND
        (SELECT COUNT(*) FROM batch_impact_metrics WHERE batch_id = 'b0000000-0000-4000-9999-000000000001') = 1 AND
        (SELECT COUNT(*) FROM batch_anomalies WHERE batch_id = 'b0000000-0000-4000-9999-000000000001') = 1,
        'PASS', 'FAIL'
    ) AS result;

-- ============================================================================
-- SCENARIO 8: Negative Constraint Assertions (Documentation / Manual Validation)
-- The following operations are guaranteed to be REJECTED by MySQL constraints:
--
-- 1. Duplicate receipt for same batch:
--    INSERT INTO batch_receipts (receipt_id, batch_id, ...) VALUES ('rc...', 'b0000000-0000-4000-9999-000000000001', ...);
--    --> ERROR 1062 (23000): Duplicate entry for key 'uq_receipt_batch'
--
-- 2. Invalid MIME type in batch_evidence:
--    INSERT INTO batch_evidence (..., mime_type, ...) VALUES (..., 'application/zip', ...);
--    --> ERROR 3819 (HY000): Check constraint 'ck_evidence_mime_type' is violated.
--
-- 3. Oversized file (> 5 MiB):
--    INSERT INTO batch_evidence (..., file_size_bytes, ...) VALUES (..., 5242881, ...);
--    --> ERROR 3819 (HY000): Check constraint 'ck_evidence_file_size' is violated.
--
-- 4. Negative treatment weight:
--    INSERT INTO batch_treatments (..., recycled_kg, ...) VALUES (..., -10.00, ...);
--    --> ERROR 3819 (HY000): Check constraint 'ck_treatment_amounts_non_negative' is violated.
--
-- 5. Invalid anomaly code:
--    INSERT INTO batch_anomalies (..., anomaly_code, ...) VALUES (..., 'UNKNOWN_ERROR', ...);
--    --> ERROR 3819 (HY000): Check constraint 'ck_anomaly_code' is violated.
--
-- 6. Orphan batch_id (foreign key violation):
--    INSERT INTO batch_receipts (..., batch_id, ...) VALUES (..., 'b9999999-9999-9999-9999-999999999999', ...);
--    --> ERROR 1452 (23000): Cannot add or update a child row: a foreign key constraint fails ('fk_receipt_batch')
-- ============================================================================

-- Clean up test fixture transaction (rollback cleanly leaves zero test traces)
ROLLBACK;
