# Verification evidence

Date: 2026-09-16

This document records scoped evidence for the checked-in source. It does not claim production readiness, device shipment, notarization, or App Store release.

## Environment

- Repository remained on the existing `main` branch.
- Swift toolchain: Xcode 27.0, build 27A266a; the plan specifies Xcode 26.6 and the project targets Apple platform version 26.0.
- Codex CLI: `codex-cli 0.154.0-alpha.6.2`; `codex login status` reported an existing ChatGPT sign-in.
- No personal health records were used. All fixture data was synthetic and temporary.

## verified locally

- `swift build --build-tests` completed successfully with the installed Swift toolchain.
- The direct `xctest` invocation executed 23 `HealthCoachKitTests` with 0 failures. Coverage includes persistent SQLite restart, atomic meal deletion/cancellation, transaction rollback and payload limits, two-way outbox/cursor ordering, interrupted snapshot staging, consistent job snapshot context, cancellation/retry generations and late-result history, pause acknowledgment, replacement pairing, deterministic health aggregation, HealthKit cross-midnight/DST dates, live-workout summary validation/rejection and persistence, and Watch queue ordering, duplicate delivery, finish-session idempotence, original program revision, restart, retry, and terminal error retention.
- A real Network.framework loopback listener/client exchange accepted the valid pairing PSK and rejected the wrong credential. The framing tests also reject malformed and oversized frames.
- The real `healthcoach-mcp` executable initialized over official MCP Swift SDK stdio, listed the exact nine read-only tools, and served bounded reads from a synthetic SQLite store.
- A direct App Server protocol probe using the installed binary completed `initialize` and `mcpServerStatus/list` with the same `--strict-config --disable apps` process arguments used by the Mac adapter; the effective `healthcoach` server exposed the exact nine-tool catalog even while reusing the existing sign-in. The client parser handles the installed CLI's native JSON `NSArray`/`NSDictionary` representation.
- Fresh Swift 6 source typechecks passed for all three native targets against their platform SDKs: iOS, macOS, and watchOS. These checks used fresh temporary HealthCoachKit modules so they included the current shared source; the Watch check included the real HealthKit workout-session controller, recovery delegate, and SwiftUI UI.
- The checked-in Xcode project, three shared schemes, iOS/macOS/watchOS property lists, and the Watch HealthKit entitlement passed structural/property-list lint checks. The iOS target contains the Watch embed phase and target dependency; the Watch property list declares its iPhone companion, HealthKit usage text, and `workout-processing` background mode.
- The installed CLI's App Server help and generated protocol schemas were captured under `docs/generated/codex-app-server/`. The implementation uses the current `thread/start`, `turn/start`, `mcpServerStatus/list`, output-schema, read-only sandbox, and `priority` service-tier fields.

## blocked

- Full `xcodebuild` scheme builds and native app launches are blocked on this machine because Xcode's license has not been accepted. Direct Swift package builds and the three strict source typechecks are not substitutes for signed/simulator app artifacts. No signing team or signing credential was invented.
- The synthetic live App Server test reached the real App Server/MCP startup with the configured `gpt-5.6-luna` / `max` / `priority` settings and attempted a model turn, but the external model turn produced no terminal response during the bounded observation window. The App Server and helper were stopped, and no success is claimed for the live model result. The independently testable App Server protocol, MCP adapter, output schema, validation, persistence, and job-generation paths remain verified locally.

## not run

- Physical iPhone HealthKit authorization, anchored observer delivery, deleted-sample delivery, background execution, and real HealthKit data behavior.
- Physical iPhone camera QR scanning, same-LAN Bonjour discovery, TLS pairing between separate Apple devices, foreground reconnect behavior, and interrupted real-device bootstrap.
- A paired physical Apple Watch's HealthKit authorization, live heart-rate/active-energy sensor values, workout save, interrupted-workout recovery, `transferUserInfo` delivery, background wake behavior, application-context replacement, and end-to-end iPhone canonical application. The watchOS Simulator does not support `transferUserInfo`; deterministic queue/protocol logic and live-summary validation were tested locally instead.
- App signing, provisioning, notarization, App Store packaging, and release distribution.
