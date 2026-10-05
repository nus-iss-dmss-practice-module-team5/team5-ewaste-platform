--liquibase formatted sql
--changeset team5:EWCSB3-028 dbms:mysql
--comment: Recycling and recovery treatment outcomes per batch (Decision D1).
CREATE TABLE batch_treatments (
    treatment_id        VARCHAR(36) NOT NULL,
    batch_id            VARCHAR(36) NOT NULL,
    facility_org_id     VARCHAR(32) NOT NULL,
    treated_by          VARCHAR(32) NOT NULL,
    reused_kg           DECIMAL(10,2) NULL,
    recycled_kg         DECIMAL(10,2) NULL,
    disposed_kg         DECIMAL(10,2) NULL,
    unknown_kg          DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    treatment_method    VARCHAR(64) COLLATE utf8mb4_0900_as_cs NOT NULL,
    completed_at        DATETIME(6) NOT NULL,
    created_at          DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

    CONSTRAINT pk_batch_treatments PRIMARY KEY (treatment_id),
    CONSTRAINT uq_treatment_batch UNIQUE (batch_id),
    CONSTRAINT fk_treatment_batch
        FOREIGN KEY (batch_id) REFERENCES ewaste_batches (id) ON DELETE RESTRICT,
    CONSTRAINT fk_treatment_facility_org
        FOREIGN KEY (facility_org_id) REFERENCES organisations (organisation_id),
    CONSTRAINT fk_treatment_treated_by
        FOREIGN KEY (treated_by) REFERENCES users (user_id),
    CONSTRAINT ck_treatment_amounts_non_negative CHECK (
        (reused_kg IS NULL OR reused_kg >= 0.00) AND
        (recycled_kg IS NULL OR recycled_kg >= 0.00) AND
        (disposed_kg IS NULL OR disposed_kg >= 0.00) AND
        unknown_kg >= 0.00
    ),

    INDEX idx_treatment_facility (facility_org_id, completed_at),
    INDEX idx_treatment_treated_by (treated_by)
) ENGINE = InnoDB
  DEFAULT CHARACTER SET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci;

--rollback DROP TABLE batch_treatments;
