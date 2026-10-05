--liquibase formatted sql
--changeset team5:EWCSB3-027 dbms:mysql
--comment: Physical intake verification by facility staff upon batch arrival.
CREATE TABLE batch_receipts (
    receipt_id              VARCHAR(36) NOT NULL,
    batch_id                VARCHAR(36) NOT NULL,
    facility_org_id         VARCHAR(32) NOT NULL,
    verified_by             VARCHAR(32) NOT NULL,
    actual_category         VARCHAR(32) COLLATE utf8mb4_0900_as_cs NOT NULL,
    actual_item_count       INT UNSIGNED NOT NULL,
    actual_weight_kg        DECIMAL(10,2) NOT NULL,
    condition_assessment    VARCHAR(32) COLLATE utf8mb4_0900_as_cs NOT NULL,
    notes                   VARCHAR(500) NULL,
    verified_at             DATETIME(6) NOT NULL,
    created_at              DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

    CONSTRAINT pk_batch_receipts PRIMARY KEY (receipt_id),
    CONSTRAINT uq_receipt_batch UNIQUE (batch_id),
    CONSTRAINT fk_receipt_batch
        FOREIGN KEY (batch_id) REFERENCES ewaste_batches (id) ON DELETE RESTRICT,
    CONSTRAINT fk_receipt_facility_org
        FOREIGN KEY (facility_org_id) REFERENCES organisations (organisation_id),
    CONSTRAINT fk_receipt_verified_by
        FOREIGN KEY (verified_by) REFERENCES users (user_id),
    CONSTRAINT ck_receipt_item_count
        CHECK (actual_item_count > 0 AND actual_item_count <= 100000),
    CONSTRAINT ck_receipt_weight
        CHECK (actual_weight_kg > 0.00 AND actual_weight_kg <= 100000.00),
    CONSTRAINT ck_receipt_condition
        CHECK (condition_assessment IN ('INTACT', 'DAMAGED', 'PARTIALLY_DAMAGED', 'DEFECTIVE', 'SCRAP')),

    INDEX idx_receipt_facility (facility_org_id, verified_at),
    INDEX idx_receipt_verified_by (verified_by)
) ENGINE = InnoDB
  DEFAULT CHARACTER SET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci;

--rollback DROP TABLE batch_receipts;
