# HealthCoach implementation plan

Status: independently reviewed; six findings repaired. Prepared 2026-09-16.

## 1. Product and boundaries

HealthCoach is a personal iPhone app with a small paired Mac companion and an optional Apple Watch companion. The iPhone owns user records and works offline. The Mac mirrors those records, hosts Codex, and returns validated coaching results. MCP exposes personal context to Codex. The Watch provides a compact training interface through its paired iPhone.

**Architectural rule:** Do not implement intelligence that Codex can provide. Keep state, sync, deterministic primitives, and UI in HealthCoach.

The first release implements the whole useful loop: capture a meal offline, reconnect to the Mac, run a Codex job with local context, and display the structured result on the phone. Build training, HealthKit, and coaching on this working loop.

### Fixed scope

- One person, one iPhone, one paired Mac, and an optional paired Apple Watch. No accounts, multi-user support, or multi-Mac conflict resolution.
- Native Swift 6 / SwiftUI; iOS 26, macOS 26, and watchOS 26 minimum. The development machine has Xcode 26.6.
- No application backend, cloud database, CloudKit, Supabase, Firebase, AWS, custom OpenAI HTTP client, nutrition catalog, large exercise catalog, ML model, or recommendation algorithm.
- Local SQLite databases, encrypted local network sync, a durable queue, and a read-only MCP executable.
- Codex generates meal estimates, complete training programs with cached alternatives, progression suggestions, and contextual answers. Its output is a proposal or estimate, never an authoritative measurement.
- Current repository: `MarlonJD/healthCoach`, cloned at `/Users/marlonjd/Developer/healthCoach`. Initially only LICENSE exists. Work on the existing `main` branch; no branch/worktree operations. Commit and push are explicitly authorized after implementation and verification. Preserve the license.

### Privacy and availability boundary

Local-first describes HealthCoach storage and iPhone-to-Mac sync. A local Codex App Server does not make a hosted Codex model local. Model requests and selected MCP results can be sent to OpenAI using the user's Codex account; no application API key is required.

The user explicitly accepted this boundary: data storage and device sync stay local; the Codex model connection is allowed. Explain that boundary during Codex setup and provide an analysis enable/pause control. Never use actual personal health data in development tests, claim offline hosted inference, or silently add another model provider.

Offline capture, history, cached programs, and deterministic summaries work without the Mac or internet. New analysis needs a reachable Mac, a configured Codex account, and model connectivity. Existing suggestions remain available offline.

iOS background execution is opportunistic. Reconnect on foreground, network availability while running, and allowed background opportunities. Never promise that returning home wakes a terminated or force-quit app. Keep a visible “Sync now” action and last successful sync time.

## 2. Small implementation structure

Use one repository, one local Swift package, and three native app targets:

```text
Apps/iOS/                  SwiftUI app, HealthKit reader, QR scanner
Apps/macOS/                menu bar app, Codex host, pairing window
Apps/watchOS/              small workout companion and durable set-capture queue
Packages/HealthCoachKit/   shared models, SQLite store, sync, deterministic summaries
  Sources/HealthCoachKit/
  Sources/HealthCoachMCP/  macOS stdio executable
  Tests/
HealthCoach.xcodeproj/     shared iOS, macOS, and watchOS schemes
docs/                     plan, setup, scoped verification evidence
```

Use GRDB for SQLite transactions and observation, and the official MCP Swift SDK for MCP framing and protocol handling. Pin compatible released versions and commit package resolution files. The iOS/watchOS targets must not link the MCP executable or the macOS Process-based host. Keep platform-specific HealthKit, WatchConnectivity, and Mac/LAN integration behind target boundaries or narrow platform guards. Do not add dependency injection containers, a separate server language, a web dashboard, or a generic plugin/event framework. Small protocols at the database, transport, HealthKit, and Codex boundaries are sufficient for meaningful tests.

Keep domain, persistence, sync, Codex integration, and views in separate files. Use Swift concurrency and observable app state; no global mutable service registry. Add a reproducible project-generation input only if the implementation uses a generator; do not require an uninstalled generator just to open and build the checked-in project.

## 3. Records and ownership

Use UUID identifiers, explicit schema versions, UTC timestamps, and the time zone/local date relevant to daily summaries. Numeric units are explicit: kg, cm, kcal, grams, minutes, bpm, and HRV SDNN milliseconds. Missing data is nullable, never silently zero.

Persist these small typed domains:

| Domain | Contents |
| --- | --- |
| Profile and goals | Current/target weight, optional body-fat target, experience, days/week, session duration, schedule constraints, exercise preferences |
| Measurements | Weight, waist, optional body fat; timestamp, unit, source, external ID for imported records |
| Meals | Original text, date, revisions, analysis status; per-item estimates, totals, ranges, assumptions, and user corrections |
| Training | Completed sessions and sets (exercise, reps, load, optional RIR/RPE), accepted current program, pending proposed programs |
| Exercise library | Stable canonical IDs, display names, equipment, alternatives; grows from validated programs rather than a seeded catalog |
| Equipment | User-editable available equipment and exclusions |
| Health summaries | Steps, active energy, sleep, resting HR, HRV, imported workout summaries and measurement references; source/freshness metadata |
| Corrections | Record-specific corrections and explicit reusable preferences, with original and corrected values |
| Coach jobs/results | Job ID, kind, input revision, status, attempts, request context version, output, errors, and acknowledgment |

The iPhone is the only writer of user-owned records and accepted program state. Job requests, cancel/retry intent, and analysis enable/pause policy are phone-owned; execution status and immutable results are Mac-owned. Keep these as distinct fields/message kinds on the same outboxes. The Mac never edits phone records directly. A proposed program becomes current only when accepted on the phone. Later analysis must not overwrite a corrected meal or newer accepted program.

SQLite writes that capture a record also enqueue its sync mutation and necessary job in the same transaction. Show “saved” only after commit; surface disk/write errors. Use local Application Support storage, OS file protection, local-only Keychain secrets, restrictive Mac permissions, and backup-exclusion flags for the HealthCoach database if “no cloud storage” is intended. Do not claim to control the user's existing Apple Health/iCloud settings. Never commit databases, secrets, transcripts, real health fixtures, or build products.

Use a single initial database schema. No compatibility layers or speculative migrations; retain normal schema-version checking and refuse unsupported protocol/data versions clearly.

## 4. Secure pairing and reliable local sync

### Pairing and transport

Use Network.framework Bonjour discovery and TLS-protected NWConnection/NWListener transport. App service type: `_healthcoach._tcp`. Advertise only a random peer identifier and protocol version; names and health information do not belong in discovery metadata.

Choose QR pairing for v1, not a six-digit shared secret. The Mac creates a cryptographically random 256-bit pairing credential and random pair ID. Show them only in a short-lived QR pairing window, alongside the discovered Mac identifier and protocol version. The phone scans the QR locally. Store the credential in each device's non-synchronizing Keychain. Use the platform TLS pre-shared-key API with that credential so the first connection and every later connection authenticate and encrypt before any health payload is exchanged. Do not implement custom encryption, accept arbitrary certificates, or send the credential over a plaintext socket.

First verify a real TLS-PSK handshake on the installed Apple SDK/runtime using synthetic payloads. Keep pairing credentials pending until both endpoints complete an authenticated acknowledgment, tolerate reconnect after a lost acknowledgment, expire unclaimed QR credentials, and stop advertising the pairing window after success. Persist successful credentials for automatic reconnect. Support unpair on either side; reject revoked credentials. Rekeying means pairing again, not a new key-management system.

Declare the required local-network, Bonjour, camera, and HealthKit usage descriptions/capabilities. The QR scanner and HealthKit remain optional: manual capture works if permissions are unavailable. No remote access, relay, port forwarding, or LAN exposure of Codex/MCP.

### Sync protocol

Use a versioned, length-prefixed Codable message envelope with strict size limits (for example 1 MiB/frame), bounded batches (for example 100 records), explicit type validation, and an authenticated peer ID. Reject malformed, oversized, unsupported-version, and wrong-owner mutations before database writes.

Keep two simple ordered outboxes: iPhone user mutations/job commands to Mac, and Mac status/results to iPhone. Each sender owns a monotonically increasing sequence and UUID mutation ID; cursors belong to a pair ID and sender, never to the device clock. Receivers durably apply a batch and record the cursor in one transaction before acknowledging it. Resend after a disconnect; duplicate IDs are harmless. Do not infer success from socket delivery alone.

Edits create a new revision; deletes create a tombstone. Source revisions, not device clocks, decide whether a record can be replaced. A receiver cannot skip a sequence gap. For a new pair, transfer a bounded snapshot with a snapshot ID, source watermark, explicit completion marker, and pair-scoped fresh cursors. Stage its batches and activate the snapshot/cursor only in the completion transaction; resume or discard an incomplete transfer without exposing partial state to the worker. Deliver incremental phone mutations after the snapshot watermark. Snapshot data includes user state, pending job commands, accepted programs, and cached historical results. This bootstrap path may restore immutable results authored by a previous Mac while preserving their original provenance; that exception does not permit wrong-owner live mutations. A replacement Mac starts its result stream in the new pair, and cannot rerun jobs already satisfied by restored results. A schema/database reset is an explicit local reset, not automatic silent data loss.

Keep one reconnect loop with cancellation and capped backoff. Reconnect triggers sync; incoming committed jobs trigger the Mac worker; result commits trigger reverse sync. UI displays disconnected, pairing, syncing, Codex unavailable, pending, failed, and last-success state without exposing transport internals.

## 5. Durable Codex jobs

The queue is persisted, not an in-memory array. Job kinds: `analyzeMeal`, `generateProgram`, `suggestProgression`, and `answerQuestion`. Exercise alternatives are required within generated programs and may also be requested through a coaching question. Questions can be captured offline.

Keep one Mac worker and one active turn initially. Job states: queued, running, succeeded, failed, and cancelled; receiving/sync acknowledgment is tracked separately. The phone assigns a request generation, increments it on explicit retry, and owns cancellation intent. Mac execution events echo the generation and source revision. Reject events/results for a cancelled/deleted request or older generation regardless of arrival order; late `running`/`succeeded` status cannot override phone intent. The Mac interrupts a known turn when cancellation arrives. Persist attempts, thread/turn references where supported, and the request's source revision. On interruption, resolve known turn state when possible; otherwise allow a bounded retry. Back off transient failures, leave auth/network failures pending with a reason, and stop repeated schema failures after a small limit with a retry action.

Pausing analysis gates new phone submissions immediately and queues a versioned policy update/cancellation intent for pending work. The Mac checks its latest acknowledged policy before dispatch. If disconnected, show that pause is waiting to reach the Mac: jobs already delivered there may run until the pause is received. The Mac has an immediate local pause control too. Do not imply that disconnected revocation is instantaneous or that already transmitted model data can be recalled.

End-to-end execution is at-least-once. Completion is idempotent: accept at most one valid result for a job/revision; a timeout must not create a second meal/program. Never promise exactly-once model billing. Stale results can be retained as history but cannot replace a newer correction, deletion, or accepted program.

### Host and trust boundary

The Mac launches the installed `codex app-server` with stdio using an explicit executable path and argument array. It owns and stops that subprocess. No shell interpolation. Probe the binary, protocol, account status, and model availability; distinguish missing installation, sign-in required, offline, and ready. Reuse the user's established Codex sign-in through supported interfaces; never read or copy authentication secrets into HealthCoach storage.

Use an application-specific working directory and per-session configuration. Enable only HealthCoach's required read-only MCP server. Disable inherited external MCP servers/plugins, shell/file editing, web browsing, and other write tools using supported configuration. The implementation must verify the actual effective tool catalog and restrictions; a prompt saying “do not use tools” is insufficient. Do not alter the user's global Codex config. If isolation cannot be verified, fail closed for automatic health jobs and report the concrete blocker.

Treat meal text, questions, corrections, and returned database strings as untrusted content. They cannot authorize tool changes or escape the application workspace. HealthCoach has no Codex-callable mutation tools. The host alone validates and persists structured results.

### App Server contract

The installed CLI is `0.154.0-alpha.6.2`. Its generated schema confirms `thread/start`, `turn/start`, `outputSchema`, ephemeral threads, and service-tier fields. Verify against the installed binary during implementation; do not copy an obsolete protocol example.

Initialize the connection, create a job-scoped thread, submit a turn with its JSON output schema, consume events, and commit only a successful completed turn's validated output. Handle refusals, interrupted turns, protocol errors, timeouts, malformed output, and restart. Prefer ephemeral threads and minimal local retention for automatic jobs where supported. Do not leave health transcripts or prompts in ordinary diagnostic logs.

At dispatch, create one consistent job-scoped SQLite snapshot using the database's supported snapshot/backup mechanism. Capture its last applied phone watermark and prerequisite revisions together. Start that job's MCP executable against this read-only snapshot, so every tool read within a turn sees the same context even while sync updates the main mirror. Remove the temporary snapshot after completion/cancellation and clean abandoned snapshots at startup; it is not another persistent database tier. Attach the watermark and relevant source/profile/goals/equipment/current-program revisions to the result. On phone acceptance, recheck the source revision, equipment exclusions, and accepted-program revision; visibly flag relevant context changes instead of silently applying an obsolete proposal.

Use a bounded job-specific prompt plus MCP context. Program generation includes goals, schedule, equipment, preferences, current program, recent training, nutrition, and recovery. Progression includes the relevant exercise/session history. A question can request a wider bounded date range. Never dump the entire lifetime database into every prompt.

## 6. MCP and output contracts

Use the official Swift MCP SDK and stdio, with read-only SQLite access to the Mac mirror for interactive context queries or the fixed job snapshot for automatic work. The executable accepts its database path as an explicit argument, writes protocol data only to stdout, and writes redacted diagnostics to stderr. No HTTP listener is needed.

Keep the tool surface narrow: `get_profile`, `get_goals`, `get_measurements`, `get_health_metrics`, `get_meals`, `get_workouts`, `get_current_program`, `get_equipment`, and `get_user_corrections`. The profile/program responses can include preferences and relevant exercise-library entries; add a separate exercise query only if an actual flow needs it. History tools accept bounded date ranges and stable cursors; enforce row and output-size limits in code. All outputs identify units, missing/stale data, and relevant revisions. No arbitrary SQL, file-path, executable, or network-URL tool inputs.

Validate results with typed decoding and domain constraints after JSON schema enforcement:

- Meal: source meal/revision, components, estimated quantities, kcal/macros, low/central/high kcal range, and assumptions. Values are finite and nonnegative; range ordering is consistent. No guessed output when Codex is unavailable. User quantity/macro corrections invalidate the prior estimate and queue reanalysis or accept an explicit user-entered value with provenance.
- Program: program ID/revision, days, ordered exercises, stable exercise IDs, sets, rep ranges, optional RIR/RPE, progression text, equipment, and cached alternatives for each exercise. Validate unique IDs/references, positive ordered ranges, and incompatibility with explicitly excluded equipment. Do not invent exercise science rules in validation.
- Progression: exercise ID, source session/revision, suggested next load/rep range when applicable, rationale and assumptions. Apply only as a displayed proposal.
- Coaching: answer text, referenced local date ranges/records, uncertainty/limitations, and optional structured suggestions. Do not present speculative causes as measured diagnoses.

Exercise IDs are stable lower_snake_case identifiers, checked for collisions and references. Keep source model/job, generation time, and input revision with results. Small deterministic validation is part of data integrity, not a recommendation engine.

## 7. HealthKit normalization

Read only the requested optional types: steps, active energy, sleep, workouts, resting heart rate, HRV SDNN, body mass, and body-fat percentage. No HealthKit writes in v1. Store waist manually. Request permissions in context and keep manual features usable without them. An empty read cannot reliably distinguish denied access from no data; show “unavailable/no data,” not a fabricated permission diagnosis or zero.

Use HealthKit statistics APIs for cumulative daily steps/energy and suitable averages for resting HR/HRV. Do not sum raw Watch and phone sample streams yourself. Preserve units and source/freshness metadata. For sleep, exclude in-bed/awake durations and merge overlapping asleep intervals before counting; handle midnight and time-zone boundaries explicitly. Imported workouts and measurements have stable HealthKit IDs for import deduplication. Keep HealthKit activity/workout totals and manually logged strength-session totals separately labeled; do not add them together or guess that matching timestamps identify one session. For daily weight, use the latest manual measurement for that day when present, otherwise the latest HealthKit measurement; keep all original records and show the chosen source. This deterministic source precedence avoids counting the same weight twice without claiming to identify cross-source duplicates.

Register observer queries at app launch and use persisted anchored-query cursors per type to detect additions/deletions. Persist the minimal sample-ID-to-affected-day metadata needed to recompute deleted or changed historical days. Commit new anchors, normalized changes, and their outbox mutations atomically. Finish the HealthKit delivery completion handler promptly after local ingestion (also on handled errors); never wait for LAN sync or Codex in that callback. Recompute affected days with the same rules; send replacements or tombstones, not increment-only totals. Initial import is bounded (for example the last 90 days), with the imported range visible. No unbounded raw history ingestion.

Daily data carries the day interval and aggregation time zone. Define 7-day weight average as the mean of available daily weight values over seven calendar days, with a documented within-day/source precedence; expose sample-day count and missing days. Sleep and HRV remain descriptive metrics; there is no recovery score or adaptive training algorithm.

## 8. App flows

### iPhone

- **Today:** quick meal/weight/waist capture, deterministic daily totals and 7-day weight trend, HealthKit summaries, sync status and pending count.
- **Meals:** text capture, history, pending/error states, estimated result with range/assumptions, and correction editing.
- **Training:** current accepted program, cached alternatives, session/set logger, history, equipment settings, new-program and progression requests. Logging works offline.
- **Coach:** question entry, queued questions, received answers/proposals, accept a proposed program.
- **Settings:** profile/goals/preferences, HealthKit access, pairing/unpair, Codex-analysis disclosure/control, sync now.

Use native forms, lists, sheets, accessible labels, Dynamic Type, and clear empty/error states. A custom design system, onboarding wizard, gamification, social features, and notifications are unnecessary for this version.

### Mac

A menu bar app shows paired-device status, Codex readiness, pending jobs, and last error. Its small settings/pairing window contains QR pairing, executable/account readiness, sync status, and a user-controlled launch-at-login option using ServiceManagement. Package the MCP executable as a helper and resolve its actual built path. The companion must not depend on a developer terminal running beside it.

### Apple Watch — bounded companion addition

The user requested a Watch app if it keeps the plan modest. Add a SwiftUI companion that shows the cached accepted workout/day, current/next exercise, and set targets; allows session start, quick set/reps/kg entry (optional RIR), and session completion; and displays pending/synced/error state. This is training capture and cached UI. Keep existing Apple Watch-to-HealthKit collection; do not add a live heart-rate/energy workout engine, independent Mac/Codex connection, Watch meals, complications, or widgets to this addition.

Use WatchConnectivity with the paired iPhone: `updateApplicationContext` for small replaceable workout/session snapshots carrying monotonic phone revisions, and `transferUserInfo` for ordered commands and application acknowledgments. Activate/check the session and installed counterpart before transfer. Watch commands (`startSession`, `recordSet`, `finishSession`) have UUIDs, session IDs, per-session sequence, exercise IDs, original program revision, and typed values. Persist the queue/cache on Watch before showing a save; phone validates, deduplicates, applies into its canonical store, and enqueues existing Mac sync in one transaction before acknowledging. Finish a session only after its preceding commands commit. Watch removes acknowledged commands only; transport delivery alone is insufficient. Complete WatchConnectivity background tasks promptly and show eventual delivery honestly.

Valid offline sets remain historical facts tied to their original session/program revision even after a new program is accepted. They do not replace the current program. Deleted-session tombstones, invalid references, or malformed commands retain a visible terminal error for resolution, with the entered data preserved rather than endlessly retried or discarded. Reject older snapshots without replacing newer Watch state. Reuse existing domain models and iPhone persistence/outbox; this does not introduce another generic replication protocol or intelligence layer.

Build the Watch target and test queue restart, duplicate delivery, session ordering/completion, old-program logging, and error retention with deterministic fixtures. Real `transferUserInfo` delivery/background behavior requires paired physical devices; the Simulator does not support this API, so label that check `not run` when devices are unavailable.

## 9. Implementation order and acceptance

Each stage leaves the previous stage working. All stages are in scope; finishing the first stage is not completion.

The user explicitly reconfirmed that simplicity must not remove product features. The stages below are an implementation sequence for the complete agreed system, not a proposal to ship a reduced feature set. Simplicity applies to internal structure and avoids the custom intelligence engines and databases the user already excluded.

1. **Scaffold and durable capture.** Build both app targets and package tests; implement the initial store, profile, meal capture, queue, and minimal UI. Acceptance: capture/edit/delete a meal, restart, and observe the same saved state and pending job. Disk errors are visible.
2. **Pairing and sync.** Prove TLS-PSK with a synthetic network integration test, implement QR/Bonjour and the two outboxes. Acceptance: capture offline, sync to a real Mac store, disconnect during acknowledgment, reconnect, and see exactly one logical record. Wrong/revoked keys are rejected; stale edits/deletes cannot resurrect records.
3. **MCP and meal analysis end to end.** Add the official MCP executable, restrictive Codex host, structured meal schema, result persistence and reverse sync. Acceptance: a synthetic meal reaches a real Codex turn and a validated result returns to the phone/store with no mock replacing the live adapter. If authentication or external access is unavailable, record `blocked` for that live check while verifying adapters using protocol fixtures.
4. **Training, coaching, and Watch companion.** Add profile constraints, equipment, set logging, personal exercise library, program generation/acceptance, alternatives, progression and questions; then add the bounded Watch interface/WatchConnectivity flow above. Acceptance: the complete proposed program survives restart, its cached alternatives work offline, and late/stale results cannot replace a correction/current program. Watch set capture survives restart, command retry does not duplicate sets, and start/set/finish becomes one complete phone-side session.
5. **HealthKit.** Add permission handling, bounded initial import, observer/anchor updates and normalized sync. Acceptance: additions/deletions, overlap, midnight, DST/time-zone cases, and missing values are tested with synthetic fixtures; real-device behavior is recorded separately.
6. **Finish and publish source.** Complete the menu bar workflow, helper packaging, status/error/retry UI, launch-at-login setting, README/setup, and focused verification. Review the final diff for scope and sensitive artifacts, commit all intended source/docs on current `main`, push to `origin/main` without force, and verify that the remote head matches the local commit.

### Required verification, proportionate to risk

- Package tests for persistence/restart, transaction rollback, outbox retry/dedup/gaps, interrupted snapshot bootstrap, replacement-Mac cursor reset, tombstones, consistent job context, stale-result prevention, cancellation/retry generation, pause acknowledgment, and deterministic aggregation.
- A real local TLS connection test plus rejected credentials and malformed/oversized frames; no mock-only security claim.
- MCP initialize/list/call over real stdio using the official client or a protocol harness; confirm bounds and read-only database access.
- App Server protocol fixtures for errors/refusals/restarts and one synthetic live model smoke test when authenticated access permits; inspect effective allowed tools.
- Build the iOS and watchOS Simulator schemes with signing disabled and the macOS scheme/helper; run the desktop app and available simulators through the core capture/history/status flow where tools permit.
- Real iPhone HealthKit, camera QR pairing, same-LAN foreground reconnection and suspended/background behavior require physical-device verification. Record `not run` if unavailable. Do not call a simulator run a real-device pass.
- Clean up only processes, simulator apps, or GUI/browser sessions started for this task; preserve the user's ordinary apps and data.
- Write concise English verification evidence with literal labels: `verified locally`, `not run`, `blocked`. Do not claim production-ready, shipped to devices, notarized, or App Store released.

Do not stop at stubs, hard-coded coaching output, a fake connection indicator, or isolated model types. If an external dependency prevents a check, finish every independently implementable part and name the exact remaining gap. Do not weaken authentication or replace Codex with local heuristics to make a test pass.

## 10. Source notes

- [Codex App Server](https://learn.chatgpt.com/docs/app-server): integration lifecycle and structured turn contract. Local generated CLI schemas are the implementation authority for this installed build.
- [Official MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk): maintained Swift protocol implementation; use its documented stdio server/client.
- [GRDB.swift](https://github.com/groue/GRDB.swift): SQLite transactions, records, and observation.
- [HealthKit statistics collections](https://developer.apple.com/documentation/healthkit/executing-statistics-collection-queries): daily aggregation APIs.
- [HealthKit sleep analysis](https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis): overlapping sleep categories.
- [HealthKit queries](https://developer.apple.com/documentation/healthkit/queries): observation, anchors, and deletions.
- [HealthKit object UUID](https://developer.apple.com/documentation/healthkit/hkobject/uuid): import identity within HealthKit; it does not establish a match to a manually recorded workout.
- [HealthKit observer queries](https://developer.apple.com/documentation/healthkit/executing-observer-queries): launch registration and delivery completion.
- [WatchConnectivity data transfer](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity) and [transferUserInfo](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo(_:)): replaceable context, queued transfer, and physical-device verification boundary.
- [HealthKit background delivery entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.healthkit.background-delivery): background observation capability; this is not a guarantee of persistent local-network execution.

Independent review findings and their disposition belong in `docs/PLAN_REVIEW.md`. Update this plan before handing it to the implementation thread.
