--liquibase formatted sql
--changeset team5:EWCSB3-029 dbms:mysql
--comment: Deterministic environmental impact and recovery metrics calculated by analytics.
CREATE TABLE batch_impact_metrics (
    metric_id       VARCHAR(36) NOT NULL,
    batch_id        VARCHAR(36) NOT NULL,
    diverted_kg     DECIMAL(10,2) NULL,
    unknown_kg      DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    data_quality    VARCHAR(32) COLLATE utf8mb4_0900_as_cs NOT NULL,
    rule_version    VARCHAR(32) COLLATE utf8mb4_0900_as_cs NOT NULL,
    calculated_at   DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    created_at      DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

    CONSTRAINT pk_batch_impact_metrics PRIMARY KEY (metric_id),
    CONSTRAINT uq_impact_batch UNIQUE (batch_id),
    CONSTRAINT fk_impact_batch
        FOREIGN KEY (batch_id) REFERENCES ewaste_batches (id) ON DELETE RESTRICT,
    CONSTRAINT ck_impact_quality
        CHECK (data_quality IN ('VERIFIED_COMPLETE', 'INCOMPLETE', 'ESTIMATED')),
    CONSTRAINT ck_impact_diverted
        CHECK (diverted_kg IS NULL OR diverted_kg >= 0.00),
    CONSTRAINT ck_impact_unknown
        CHECK (unknown_kg >= 0.00),

    INDEX idx_impact_quality (data_quality, calculated_at)
) ENGINE = InnoDB
  DEFAULT CHARACTER SET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci;

--rollback DROP TABLE batch_impact_metrics;
