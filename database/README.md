# EW-101-C1 Persistence Foundation

The Sprint 1 instructions below describe the existing foundation. The master
changelog now also includes approved Sprint 2 C1 migrations 006–010, C2
prerequisites 011–017, C3 claim migrations 018–020, and C4 assignment/handoff migrations 021–025. For
EWCSB-126 deterministic batch fixtures and SQL persistence/migration checks,
see [the C1 test guide](tests/c1/README.md) and run:

```sh
./scripts/test-ewcsb126.sh
```

C1 batch fixtures require the explicit `c1-fixtures` context; the existing
`seed` context loads synthetic Sprint 1 identities and the `binary-v1` matching
policy from `seed/105-seed-matching-rule-sets.sql`. The policy seed runs once in
dev/staging, references the active platform administrator `USR-001`, and becomes
effective at migration time in UTC. It halts if the administrator is missing or
inactive, the policy version/ID already exists, or another rule set has an
overlapping activation window. Repeated Liquibase updates leave the policy and
its activation timestamp unchanged. Existing migrations are not modified.

The policy JSON matches `contracts/matching/contracts/MatchingInput.v1.schema.json`.
Recycler profiles, capabilities, capacity pools and service zones still require
configuration before a receiver can qualify for a match. This seed creates no
batches, matching results or recycler configuration. Production excludes the
`seed` context and must provision the policy with its own approved administrator
and activation time. Policies referenced by matching decisions are retained;
this seed has no destructive rollback.

For C3 claim repository, constraints and concurrent MySQL fixtures, see
[the C3 test guide](tests/c3/README.md) and run:

```sh
./scripts/test-c3-persistence.sh
```

For C4 assignment/handoff persistence, canonical outbox events and lifecycle
concurrency checks, see [the C4 test guide](tests/c4/README.md) and run:

```sh
./scripts/test-c4-persistence.sh
```

The sections below describe the original Sprint 1 foundation. Its scope exclusions
are historical; the main changelog now includes the later C1–C4 business tables.

This folder implements the Sprint 1 database foundation for:

- organisations and organisation ownership;
- the Sprint 1 role catalogue;
- seeded synthetic users;
- short-lived, revocable login sessions; and
- repeatable Liquibase migrations and database assertions.

## Scope boundary

This change deliberately does **not** create:

- the append-only audit-event table, which belongs to EW-102-C2;
- endpoint handlers or password verification code, which belong to EW-101-C2;
- the detailed permission matrix or RBAC middleware, which belong to EW-102; or
- business tables for e-waste batches, claims, collection, processing, or recycling.

Keeping these concerns separate makes the EW-101-C1 pull request small and reviewable.

## Current organisation hierarchy

```text
PLATFORM
|- SYSTEM_ADMIN
`- AUDITOR

DONOR organisations
`- DONOR

COLLECTION_OPERATOR organisations
`- COLLECTOR

PROCESSING_FACILITY organisations
`- RECYCLER
```

The `roles.allowed_organisation_type` column documents this ownership rule. The Go service should enforce it when users are created or updated. The included database test also verifies that the synthetic seed data follows the rule.

## Seeded synthetic accounts

| Email | Role | Organisation | Status |
|---|---|---|---|
| admin@ewaste.test | SYSTEM_ADMIN | PLATFORM | ACTIVE |
| auditor@ewaste.test | AUDITOR | PLATFORM | ACTIVE |
| donor1@ewaste.test | DONOR | DON-001 | ACTIVE |
| donor2@ewaste.test | DONOR | DON-002 | ACTIVE |
| collector1@ewaste.test | COLLECTOR | COL-001 | ACTIVE |
| collector2@ewaste.test | COLLECTOR | COL-002 | ACTIVE |
| recycler1@ewaste.test | RECYCLER | PROC-001 | ACTIVE |
| recycler2@ewaste.test | RECYCLER | PROC-002 | ACTIVE |
| disabled@ewaste.test | DONOR | DON-001 | DISABLED |

For the local Sprint 1 smoke test, all accounts use the synthetic password:

```text
TestOnly#2026!
```

Only bcrypt hashes are stored in `seed/103-seed-users.sql`. These accounts are test fixtures. The seed changesets use the required `seed` context and must not be applied to a real production system.

## Session model assumption

The persistence starter now assumes JWT-based authentication with server-side session revocation:

- `sessions.session_id` is the UUID for the authenticated server-side session and should be carried in access and refresh JWTs as the `sid` claim.
- `sessions.token_hash` stores a 64-character SHA-256 hexadecimal hash of the **current refresh token/JWT**. The raw refresh JWT is never stored in MySQL.
- Access JWTs are short-lived and are not stored in MySQL.
- Each individual JWT may use its own `jti`; `jti` is distinct from the shared session `sid`.

A successful login can:

1. generate a new session UUID;
2. create the access JWT and refresh JWT;
3. hash the refresh JWT with SHA-256;
4. insert the session row with `session_id`, `user_id`, `token_hash`, issue/expiry timestamps, and no revocation timestamp; and
5. return the JWTs to the client without persisting either raw JWT.

On refresh, the presented refresh JWT is hashed and compared with `token_hash`. If refresh-token rotation is enabled, replace `token_hash` with the hash of the newly issued refresh JWT. Logout or forced invalidation sets `revoked_at`; raw JWTs must never be written to the database, logs, or audit payloads.

## Changelog order

```text
001 organisations
 -> 002 roles
 -> 003 users
 -> 004 sessions
 -> 101 seed organisations
 -> 102 seed roles
 -> 103 seed users
```

The order preserves the foreign-key dependencies.

## Run locally

From the repository root:

```bash
./scripts/test-ew101-c1.sh
```

The script:

1. starts a clean MySQL 8.4 container;
2. builds a pinned Liquibase image with the MySQL driver;
3. validates the changelog;
4. applies the schema and explicit `seed` context;
5. runs the migration a second time to check repeatability; and
6. runs database assertions.

Keep the database running after the test:

```bash
KEEP_DB=1 ./scripts/test-ew101-c1.sh
```

Default local connection:

```text
Host:     localhost
Port:     3307
Database: ewaste
User:     ewaste_app
Password: ewaste-local-only
```

These defaults are for isolated local development only. Override them through environment variables when needed:

```bash
export EWASTE_DB_NAME=ewaste
export EWASTE_DB_USER=ewaste_app
export EWASTE_DB_PASSWORD='a-local-password'
export EWASTE_DB_ROOT_PASSWORD='a-local-root-password'
export EWASTE_DB_PORT=3307
```

## Suggested pull request evidence

Attach or link:

- Liquibase `validate` output;
- first successful `update` output;
- second no-op `update` output;
- the PASS table from `verify-ew101-c1.sql`;
- a schema/ER screenshot if required by the sprint; and
- confirmation that only password hashes, not raw passwords or session tokens, are stored.
