--liquibase formatted sql

--changeset team5:EWCSB129-105 dbms:mysql context:@seed labels:matching-configuration
--preconditions onFail:HALT onError:HALT
--precondition-sql-check expectedResult:1 SELECT COUNT(*) FROM users WHERE user_id = 'USR-001' AND organisation_id = 'PLATFORM' AND role_code = 'SYSTEM_ADMIN' AND status = 'ACTIVE';
--precondition-sql-check expectedResult:0 SELECT COUNT(*) FROM matching_rule_sets WHERE id = 'a1290000-0000-4000-8000-000000000001' OR version = 'binary-v1' OR retired_at IS NULL OR retired_at > UTC_TIMESTAMP(6);
--comment: Initialize the binary-v1 matcher policy for dev/staging after the seeded administrator exists.
-- The policy is the exact $defs.policy.const from MatchingInput.v1.schema.json.
-- Activate at migration time in UTC. Liquibase applies this changeset once;
-- repeated updates preserve the ID, policy and original activation timestamp.
-- Halt on an existing version or overlapping activation window; never overwrite
-- an immutable policy or silently enable two rule sets at the same time.
INSERT INTO matching_rule_sets (
    id, version, rules_json, effective_from, retired_at, created_by, created_at
) VALUES (
    'a1290000-0000-4000-8000-000000000001',
    'binary-v1',
    '{
        "categories": ["ICT_EQUIPMENT", "LARGE_APPLIANCE", "BATTERIES", "CONSUMER_ELECTRONICS"],
        "conditions": ["FUNCTIONAL", "REPAIRABLE", "END_OF_LIFE"],
        "zones": ["NORTH", "SOUTH", "EAST", "WEST", "CENTRAL"],
        "weight_scale": 2,
        "rule_ids": ["M1", "M2", "M3", "M4", "M5"],
        "predicates": {
            "M1": "ACTIVE_EXACT_CATEGORY",
            "M2": "ACTIVE_CAPABILITY_AND_PROFILE_CONDITION_AND_DATA",
            "M3": "OWNED_ACTIVE_POOL_FULL_WEIGHT",
            "M4": "ACTIVE_EXACT_ZONE",
            "M5": "EVALUATION_BEFORE_DEADLINE_AND_LEAD_ARRIVAL_AT_OR_BEFORE_DEADLINE"
        },
        "failure_precedence": ["M1", "M2", "M3", "M4", "M5"],
        "ranking": false
    }',
    UTC_TIMESTAMP(6),
    NULL,
    'USR-001',
    UTC_TIMESTAMP(6)
);

-- No destructive rollback: matching decisions may reference this policy.
-- Production must provision its own approved administrator and activation.
