# EWCSB-194 — Sprint 4 concurrency extension

`EWaste_API_Test_Plan.jmx` retains groups 00–11 and appends S4 groups 12–19. The new groups cover claim races, simultaneous handoffs, independent processing bursts and concurrent custody reads. They default to **off** (`run_s4=false`). No application code or deployment settings are changed.

## Prerequisites

- Apache JMeter **5.6.3**, Java **17**, Python **3.10+**. No JMeter plugins are required.
- A running API, matching/analytics worker, Kafka, MySQL and Redis on the same test environment. Required migrations must already be applied.
- Dedicated donor, recycler, second recycler, collector and auditor accounts. Both recyclers must be eligible for ICT_EQUIPMENT, REPAIRABLE, data-bearing batches in the configured zone. The collector must be in the primary recycler's scope. The second recycler must belong to a **different organisation**.
- At least `12 × (burst threads + 2)` kg of available matching capacity for the default `all` profile. Test-created rows remain in the database for evidence; use a disposable database or the agreed synthetic-data cleanup procedure. The runner never deletes lifecycle data.

The number of threads is the number of concurrent requests, **not the number of distinct accounts**. Threads reuse tokens from serial setup logins; the claim contenders alternate between the two recycler accounts. The handoff race uses one authorised collector on one assignment. Independent handoff bursts use that collector on distinct assignments.

## Local command line

From the repository root:

```bash
cp artifacts/jmeter/data/credentials.example.properties /tmp/ewaste-jmeter-private.properties
chmod 600 /tmp/ewaste-jmeter-private.properties
# Edit the private file and enter dedicated test account credentials.
export JMETER_BIN='/path/to/apache-jmeter-5.6.3/bin/jmeter'
export JAVA_HOME='/path/to/jdk-17'
./scripts/run-jmeter-s4.sh --host http://localhost:8080 --credentials /tmp/ewaste-jmeter-private.properties
```

Replace the host explicitly with the intended dev/staging API origin when authorised to create test data there. There is no deployed-host default in the runner. Do not place passwords on the command line or commit the private properties file. Java properties syntax applies: escape a literal backslash as `\\`.

Useful variants:

```bash
# One claim race, its replay and the final state read.
./scripts/run-jmeter-s4.sh --host http://localhost:8080 --credentials /tmp/ewaste-jmeter-private.properties --profile claim

# Independent processing waves without the custody read phase.
./scripts/run-jmeter-s4.sh --host http://localhost:8080 --credentials /tmp/ewaste-jmeter-private.properties --profile burst

# Explicitly opt into 100-thread bounded bursts, never multiple 100-thread groups at once.
./scripts/run-jmeter-s4.sh --host http://localhost:8080 --credentials /tmp/ewaste-jmeter-private.properties --settings artifacts/jmeter/data/s4-burst-100.properties

# Also run SELECT-only integrity checks against the SAME database as the API.
./scripts/run-jmeter-s4.sh --host http://localhost:8080 --credentials /tmp/ewaste-jmeter-private.properties --mysql-config /path/to/private-mysql.cnf --database ewastedb
```

Profiles are `all`, `claim`, `handoff`, `burst`, `custody`. `custody` first creates and completes its own processing fixtures. The public properties files control counts, ramp, bounded polling, timeouts and pacing. Start with `s4-functional.properties`: two race contenders, four processing batches, four custody readers and two read cycles. `s4_burst_threads` must be a multiple of four to retain all golden cases. Claim threads must be even and at least two. Counts are capped at 100. The barrier timeout must exceed the thread ramp.

Five setup logins are paced at 6.5 seconds by default to respect the shared login limit. Other traffic may still consume this limit. A 429 is a failure, not a successful race loser. Setup must leave enough token lifetime for subsequent phases; the plan fails clearly if insufficient. Reduce the pool or use the agreed test-token lifetime rather than silently refreshing during measured operations. Session tokens are held in memory and cleared at teardown; server sessions expire normally. Run on a single JMeter engine: shared fixture pools and barriers are not distributed-test compatible.

## JMeter UI

Launch from the repository root with this command, or open the JMX through the GUI:

```bash
"$JMETER_BIN" -q /tmp/ewaste-jmeter-private.properties -Jhost=http://localhost:8080 -Jrun_s4=true -Js4_profile=all -t artifacts/jmeter/EWaste_API_Test_Plan.jmx
```

Disable legacy groups 00–11 for an S4-only run. Leave **Run Thread Groups consecutively** and **Run tearDown Thread Groups after shutdown** enabled. Leave S4 setup, winner verification and teardown enabled. Select a profile through User Defined Variables. The CLI runner makes an isolated selected-plan copy that disables legacy groups and GUI listeners automatically; it never changes your saved enable/disable choices. GUI View Results Tree can display credentials in login bodies/headers, so do not share those samples. Use CLI evidence for sharing.

Keep the `data/s4-golden.json` file beside the JMX in its `data` subfolder. S4 resolves relative input/output paths against the opened JMX folder, including the original `artifacts/jmeter/…` defaults. Absolute paths also work. For a JMX copied elsewhere, set `s4_data_file` to the full path of the JSON and `s4_output` to a writable folder. A fresh `s4-<run-id>` subfolder is created on every run.

If `SETUP_S4_INIT` returns `CONFIG_FAILED`, read its **Response message** or **Response data**. The message now names the failed setting without exposing its value. Check `s4_data_file`, `s4_output` and the required email/password variables. Profile `all` needs donor, recycler, recycler2, collector and auditor; `claim` needs donor and both recyclers; `handoff` needs donor, recycler and collector; `burst`/`custody` also need auditor. These are local setup failures before any HTTP call. Do not send credentials when sharing the error.

If `AUX_BIND_HANDOFF` fails, read **Response data** for the specific setup, token or fixture problem. A handoff-only run needs `run_s4=true`, `s4_profile=handoff`, and groups **S4 12, 15, 16 and 19** enabled together, with **Run Thread Groups consecutively** checked. Start the whole test plan, not S4 15 alone. S4 12 logs in and creates the matched, claimed and assigned batch plus its frozen handoff payload. This runtime state cannot be reused after teardown or a JMeter restart. The claim race has the same prerequisite through S4 12. The generator preserves existing User Defined Variables, including credentials and fixture IDs.

## Scenarios and endpoint coverage

| Groups | Scenario | Requests and assertions |
|---|---|---|
| S4 12 | Tagged setup and matching | Login, create draft, submit, bounded opportunity reads. Every batch has a fresh ID and `S4LD:<run>:<scenario>:<index>` note. Both recycler organisations see the same claim candidate/version/epoch. |
| S4 13–14 | Claim race | Concurrent `POST /batches/{id}/claim` with distinct keys and one frozen version/epoch. Exactly one 200 and N−1 409 responses with CONFLICT/STALE_VERSION. Overlapping requests, start spread, unchanged winner replay and persisted APPROVED state. SQL requires exactly one claim/reservation/command/audit/outbox. |
| S4 15–16 | Same-assignment handoff race | Concurrent `POST /assignments/{id}/handoff` with the same payload/version but distinct keys. Exactly one success, N−1 conflicts, one handoff and COLLECTED state. Winner replay retains durable identifiers. |
| S4 17 | Independent processing bursts | Synchronised waves named `TX_CLAIM`, `TX_ASSIGN`, `TX_HANDOFF`, `TX_RECEIPT`, `TX_TREATMENT`. Each thread owns one batch. A barrier precedes each write wave. Actual receipt and treatment values, final COMPLETED state and golden analytics are checked. |
| S4 17 | Rejections and retries | Donor receipt denied; stale receipt and zero count rejected; changed payload under a used key conflicts. Original handoff/receipt/treatment keys replay after completion without changing durable identifiers. Donor custody read denied. |
| S4 18 | Concurrent custody reads | `STD_TIMELINE`, `STD_ANOMALIES`, `STD_IMPACT`; two timeline reads, one anomaly read and one impact read per cycle (50/25/25). Assert identities, one transition each, exact flags/metrics, stable timeline/result IDs and unchanged batch state/version. |
| S4 19 | Evidence export | Manifest of generated fixtures, winning/losing commands, correlations and timestamps; clear shared token state. |

Paths above are under `/api/v1`. Preparation includes collector scope and assignment reads. `data/s4-golden.json` is versioned `s4-jmeter-v1`, using `d3-v1`: clean, discrepant/partially allocated, all outcome amounts absent, and explicit zero outcome. All weights are kg, returned as two-decimal strings. Missing values stay null; they are not treated as zero. Evidence remains optional and absent in these bursts; evidence upload/download and failed-collection recovery remain covered by the preserved original groups.

Custody assertions use only generated batch IDs. `/audit/impact` returns an unpaginated collection, so the plan finds each expected batch within it without assuming other runs have been deleted. It does not equate whole-environment totals to this run's totals. `TreatmentRecorded` is the audit action; `RecyclingCompleted` is its outbox event.

## Results and pass criteria

Each CLI run creates a private directory under `artifacts/jmeter/results/`:

- `results.jtl`, `jmeter.log`: sampler status, safe failure messages, request-start timestamps and elapsed times. Response bodies and headers are not saved by the runner.
- `run.json`: explicit target, public settings, source commit and SHA-256 of the plan and fixture file.
- `s4-*/manifest.json`, `requests.jsonl`: batch, assignment, command-key, source-event and correlation identifiers, role/organisation, expected version, request start/end and result. No tokens or passwords.
- `summary.json`, `summary.md`: functional outcome and **nearest-rank** p95 for each named operation. Standard reads use the 2,000 ms target; confirmed writes use 3,000 ms. Unexpected errors are reported against 1%. Races are reported separately.
- `reconciliation.sql`: literal batch IDs and keys, no session variables. Run against the API's actual database and retain output. Every `violations` value must be **0**. Optional `--mysql-config` executes these read-only checks and returns nonzero if any fails.

Functional pass requires every assertion and intended sample count to pass, including **one race winner** and valid completion of all processing fixtures. Native HTTP sampler elapsed times exclude fixture preparation, synchronising barriers, pacing and Groovy assertion time. `SETUP_*`, `AUX_*`, `NEG_*` and `REPLAY_*` samples are retained separately and excluded from operation latency statistics. Intentional denials/conflicts must match the expected status/code; other errors fail the run. The runner returns nonzero for JMeter assertion failures even when JMeter itself exits zero.

A successful HTTP-only run is **not** complete database evidence. SQL checks cover state/version, claim/reservation, handoff, receipt, treatment and result uniqueness, command/audit/outbox counts, golden persisted metrics, and absence of writes for rejected keys/correlations. Retain SQL output alongside the HTTP results before claiming durable integrity. These short functional bursts do **not** certify sustained D8 load, event latency below 10 seconds or ArchSS scaling. Poll duration is not event-processing latency; those campaigns need their separate duration and database/event timestamp evidence.

## Maintain and validate locally

```bash
# Regenerate only S4 groups in the existing plan; legacy groups are preserved.
python3 scripts/jmeter/build_s4_extension.py

# Actual JMeter execution against a temporary 127.0.0.1 contract double.
JMETER_BIN="$JMETER_BIN" python3 -m unittest discover -s tests/jmeter -p 'test_*.py' -v
```

The local double checks script execution and deliberately injects two claim winners, wrong analytics metrics and missing matching results. It is not backend, Kafka or MySQL acceptance evidence. Use a real disposable stack or the authorised target for those results.

Local validation on 15 October 2026: the complete appended plan passed on the loopback double. All five smoke tests passed, including the four intentional failure cases. The new golden values were also compared with `matcher.analytics.evaluate` in this repository. Groups 00–11 were compared with the original plan and retained unchanged; regenerating S4 twice produced identical bytes. No dev/staging requests or real-MySQL reconciliation were executed for this validation.

Local validation on 16 October 2026: all ten JMeter checks passed after the setup-path correction. Five additional checks execute the setup sampler from a different launch directory and verify missing/unreadable data, malformed JSON, missing credentials and an invalid output folder. Diagnostics do not echo credential or malformed-file contents. The existing five workflow checks still pass against the loopback double; no deployed API was contacted.

The previously ignored plan and public inputs are now explicitly allowed by `.gitignore` so they can travel with the branch. Other reports, result directories and private properties remain ignored. The existing plan exceeds 1 MB, so only this exact JMX path is exempted from the pre-commit file-size check; secret and code-security checks remain enabled.
