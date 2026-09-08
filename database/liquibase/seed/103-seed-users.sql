--liquibase formatted sql

--changeset team5:EW101-C1-103 dbms:mysql context:@seed labels:synthetic-test-data
--comment: Seed synthetic users for local/test environments. All seeded accounts use the test password TestPassword123!; only bcrypt hashes are stored.
INSERT INTO users (
    user_id,
    email,
    display_name,
    password_hash,
    role_code,
    organisation_id,
    status
) VALUES
    ('USR-001', 'admin@ewaste.test',      'Platform Administrator',            '$2a$10$eqtjY9kouksw0GBkZywi2u7XNNOKK6xhJ4wDMWhGyt8GqxyePTqf6', 'SYSTEM_ADMIN', 'PLATFORM', 'ACTIVE'),
    ('USR-002', 'auditor@ewaste.test',    'Platform Auditor',                  '$2a$10$0kW5aL1ib793gik.nyfySO2MCAWTTrwQ0yWvnyjLSHIa0p3fSN2Te', 'AUDITOR',      'PLATFORM', 'ACTIVE'),
    ('USR-003', 'donor1@ewaste.test',     'Green Office Donor',                '$2a$10$IthoXHGMN8iZ.nsyuQEoduUNJi.W20XZxvd3xhqFGNnVe.TSFwikO', 'DONOR',        'DON-001',  'ACTIVE'),
    ('USR-004', 'donor2@ewaste.test',     'Community Hub Donor',               '$2a$10$YQWJZKRRRKX3IKPdznssw.9lq0sAWickTxotV40giNWi50v.Jq4Ve', 'DONOR',        'DON-002',  'ACTIVE'),
    ('USR-005', 'collector1@ewaste.test', 'Green Collect Operator',            '$2a$10$ts64eZH88gbkK.bA3oaZ3u55JU4tbG2yS47JdHbFWnEd19lYA9zc2', 'COLLECTOR',    'COL-001',  'ACTIVE'),
    ('USR-006', 'collector2@ewaste.test', 'EcoPickup Operator',                '$2a$10$Ftzm8yZjvAVVqalE7zaJ4.yxc3T/YrE7mK9Wyld8c47yt/7GJLMya', 'COLLECTOR',    'COL-002',  'ACTIVE'),
    ('USR-007', 'recycler1@ewaste.test',  'EcoCycle Processing Facility',      '$2a$10$eESm.7EBWSiBq.pRZoNTH.pcG03llcpf/m0fZJ3f8eaP.RU3RmgaK', 'RECYCLER',     'PROC-001', 'ACTIVE'),
    ('USR-008', 'recycler2@ewaste.test',  'RenewTech Processing Facility',     '$2a$10$iUVZWR/70ZFXS6e6bul7R.IqTs61G8PxGjJsHY1Ll7vvK1zNj6NF.', 'RECYCLER',     'PROC-002', 'ACTIVE'),
    ('USR-009', 'disabled@ewaste.test',   'Disabled Donor',                    '$2a$10$8C0i3z0DKQHPLozo4EUWB.YreZ1MMmUX5Is2W1i6nBJ/R/N8sliIu', 'DONOR',        'DON-001',  'DISABLED');

--rollback DELETE FROM users WHERE user_id IN ('USR-001', 'USR-002', 'USR-003', 'USR-004', 'USR-005', 'USR-006', 'USR-007', 'USR-008', 'USR-009');
