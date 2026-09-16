# HealthCoach

HealthCoach is a native, local-first health and training system composed of three Apple targets:

- **iPhone** is the canonical offline store for meals, nutrition corrections, measurements, goals, training sessions and sets, accepted programs, equipment, preferences, HealthKit summaries, coaching jobs, and cached results.
- **Mac menu bar companion** keeps a local mirror, advertises a short-lived pairing credential, accepts encrypted sync from the iPhone, hosts the installed Codex App Server, and runs durable structured jobs through the read-only `healthcoach-mcp` helper.
- **Apple Watch companion** is a small cached workout and set-capture interface. It communicates only with the paired iPhone through WatchConnectivity; the iPhone remains canonical.

The system deliberately has no application backend, cloud database, CloudKit, account system, custom OpenAI HTTP client, nutrition catalog, large exercise catalog, ML engine, or recommendation engine. Codex supplies meal estimates with uncertainty, complete training programs with cached alternatives, progression proposals, and holistic answers from the bounded local context exposed by MCP. HealthCoach owns state, validation, synchronization, deterministic summaries, and UI.

## Repository layout

```text
Apps/iOS/                  iPhone SwiftUI app, HealthKit reader, QR scanner
Apps/macOS/                menu bar app, pairing window, Codex worker
Apps/watchOS/              cached workout companion, live HealthKit workout, and WatchConnectivity queue
Packages/HealthCoachKit/   shared Swift models, SQLite store, sync, summaries
Packages/HealthCoachKit/Sources/HealthCoachMCP/
                           read-only MCP stdio executable
Packages/HealthCoachKit/Tests/
                           persistence, protocol, security, aggregation, and Watch tests
HealthCoach.xcodeproj/     shared iOS, macOS, and watchOS schemes
docs/                      reviewed plan, generated protocol schemas, verification evidence
```

## Requirements and setup

The project targets iOS 26, macOS 26, and watchOS 26 and uses Swift 6 strict concurrency. Open `HealthCoach.xcodeproj` in Xcode and choose one of the shared schemes:

- `HealthCoachIOS` builds the iPhone app and its canonical phone-side WatchConnectivity bridge.
- `HealthCoachMac` builds the menu bar companion and its MCP helper build phase.
- `HealthCoachWatch` builds the standalone watchOS companion target. Run this scheme separately when installing the optional paired Watch app; the iPhone target does not embed a legacy WatchKit Extension bundle.

Set or verify the development team and signing identities in Xcode before installing on hardware. The project may contain the locally selected team identifier, but no signing secret is committed. The minimum deployment targets and bundle identifiers are in `HealthCoach.xcodeproj/project.pbxproj` and the three target property lists.

The package pins GRDB and the official MCP Swift SDK in `Package.swift` and `Package.resolved`. The Mac build packages `healthcoach-mcp` into the app's helper directory. During local development, `HEALTHCOACH_MCP_PATH` can point at an executable helper when a bundled helper is not available.

The verification machine used for this source snapshot has Xcode 27.0 (SDK 27.0), while the implementation contract specifies Xcode 26.6 and 26.0 minimum deployment targets. See [`docs/VERIFICATION.md`](docs/VERIFICATION.md) for the scoped build, test, simulator, and physical-device evidence.

## Build and test

With an accepted Xcode license, the normal unsigned simulator builds are:

```sh
xcodebuild -project HealthCoach.xcodeproj -scheme HealthCoachIOS -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project HealthCoach.xcodeproj -scheme HealthCoachWatch -sdk watchsimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project HealthCoach.xcodeproj -scheme HealthCoachMac -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The Mac run helper is [`script/build_and_run.sh`](script/build_and_run.sh). Its `run`, `--verify`, `--debug`, `--logs`, and `--telemetry` modes build with the checked-in Mac scheme; it does not supply credentials or modify the global Codex configuration.

The package and deterministic tests can also be run without Xcode's project service by using the installed Swift toolchain:

```sh
TOOLCHAIN=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
env SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  "$TOOLCHAIN/swift" build --build-tests
```

The test suite uses synthetic fixtures only. It includes a real loopback Network.framework TLS-PSK connection, rejected credentials, bounded framing, SQLite restart/rollback/snapshot behavior, durable sync cursors/outboxes, job generations and cancellation, HealthKit date/overlap normalization, live-workout summary validation, and Watch command ordering, deduplication, completion, original-program revision handling, restart, retry, and terminal-error retention. Scoped results are recorded in [`docs/VERIFICATION.md`](docs/VERIFICATION.md).

## Local data and pairing

The iPhone writes its SQLite database under the application-support `HealthCoach` directory. The Mac keeps a separate `mac-mirror.sqlite`; a per-job SQLite backup is created for a consistent read-only MCP context and removed after the job. The Watch persists its replaceable snapshot, command queue, command UUIDs, per-session sequences, and acknowledgments in its application-support directory. Build output, databases, snapshots, health records, and credentials are ignored by Git.

On the Mac, open the menu bar companion and scan its short-lived QR code from the iPhone Settings tab. The QR contains a random 32-byte pairing secret, pair/peer identifiers, protocol version, and expiry—not health content. The secret is stored in the device-only Keychain. Bonjour advertises only the HealthCoach service and Mac peer identifier. Sync uses a Network.framework TLS pre-shared key with the pairing identity hint, length-bounded frames, authenticated peer IDs, durable two-way outboxes, cursors, and staged snapshot bootstrap. Interrupted bootstrap is discarded and retried without exposing partial state.

The iPhone reconnects opportunistically while the app is foregrounded; the Mac listener remains available while the companion runs and can be enabled at login. iOS background execution and suspended LAN delivery remain subject to Apple's scheduling limits. The UI reports pending, synced, disconnected, and error states instead of treating a queued mutation as delivered.

## Codex and MCP boundary

The Mac uses the installed Codex CLI's App Server over stdio with `--strict-config --disable apps`. Each job gets a temporary `CODEX_HOME`, restrictive `approval_policy = "never"` and `sandbox_mode = "read-only"` settings, an ephemeral thread, a read-only/no-network turn sandbox, and the `gpt-5.6-luna` model at `max` reasoning and `priority` service tier. Existing supported Codex sign-in is reused through a temporary symlink to the user's existing credential; secrets are not copied into HealthCoach storage and global Codex settings are not changed.

Before a turn, the host verifies that the effective App Server MCP catalog is exactly the nine read-only HealthCoach tools: profile, goals, measurements, normalized health metrics, meals, workouts, current program, equipment, and user corrections. The helper accepts only its explicit database path, opens it read-only, applies bounded local-date ranges and row/output limits, and writes protocol data only to stdout. It has no arbitrary SQL, filesystem, network, mutation, or second MCP-server capability. The App Server protocol reference is generated from the installed CLI in [`docs/generated/codex-app-server/`](docs/generated/codex-app-server/).

Jobs capture a consistent SQLite snapshot and prerequisite revisions before dispatch. Meal results retain ranges, assumptions, source meal revision, and corrections. Program results are validated as complete proposals, including stable exercise IDs and cached alternatives. Cancellation, retry generations, stale source revisions, malformed output, refusal, interruption, timeout, and late result history are durable states rather than silent drops.

## HealthKit and Watch boundaries

The iPhone HealthKit import is read-only and optional. It imports a bounded recent range of steps, active energy, sleep, workouts, resting heart rate, HRV SDNN, body mass, and body-fat percentage. Deterministic aggregation preserves units, freshness, source identity, manual-weight precedence for within-day summaries, sleep overlap handling, midnight/DST behavior, anchors, deleted-sample affected-day metadata, and tombstone replacements. Today surfaces the most recent HealthKit weight first and falls back to a manual weight only when no imported HealthKit weight exists; waist and body-fat values live in the occasional Body measurements check-in. Manual meals, measurements, goals, and training remain usable without iPhone HealthKit permission.

Today opens with a deterministic day-at-a-glance card that summarizes logged meals, training sets, and sync state, then offers the next relevant existing action such as meal capture, workout continuation, or Coach. It is presentation logic over persisted state, not a separate recommendation engine. The remaining cards keep the primary flows visible while using iOS 26 Liquid Glass surfaces with a material fallback on earlier supported runtimes.

The Watch receives replaceable workout snapshots with `updateApplicationContext` and sends ordered `startSession`, `recordSet`, and `finishSession` commands and acknowledgments with `transferUserInfo`. A user-started Watch workout uses the real HealthKit workout session APIs to display current/average/peak heart rate, active energy, and elapsed time; the screen also shows current-set progress and a clear finish action. The system saves the workout to HealthKit, while HealthCoach stores only the bounded final summary in the canonical phone session. Commands are persisted on Watch before they appear saved, and the phone validates, deduplicates, applies, and enqueues its existing Mac outbox transactionally before acknowledging. Valid offline sets remain tied to their original session/program revision even after a newer program is accepted. Invalid or deleted references retain their entered values and visible terminal error. Wrist temperature is not collected. There is no Watch AI or Mac connection, independent Watch sync, meals, complications, widgets, custom HealthKit sample writer, or independent workout database.

The Watch declares HealthKit permission text and `WKBackgroundModes = workout-processing`; the recovery delegate reconnects an active HealthKit session after an interruption. Physical Watch hardware is required to verify authorization, sensor values, background recovery, and queued `transferUserInfo` delivery.

## Further documentation

- [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) is the complete reviewed implementation contract.
- [`docs/PLAN_REVIEW.md`](docs/PLAN_REVIEW.md) records the independent review and Watch amendment disposition.
- [`docs/VERIFICATION.md`](docs/VERIFICATION.md) separates `verified locally`, `not run`, and `blocked` evidence, including physical-device and signing limitations.
