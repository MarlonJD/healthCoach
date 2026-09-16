# Independent plan review

Reviewed on 2026-09-16 by a separate read-only reviewer with fresh context. The reviewer did not edit the plan or implement code. Review scope: architectural completeness, avoidable complexity, secure pairing, sync/queue correctness, Codex integration, and HealthKit behavior.

Initial verdict: retain the architecture and repair six concrete protocol/behavior gaps before implementation. All six findings were accepted and incorporated into `IMPLEMENTATION_PLAN.md`.

Independent re-review verdict: **PASS — all six findings resolved; ready for implementation delegation.** The reviewer found no new architectural contradiction and confirmed that the complete requested feature scope remains included.

| Priority | Finding | Repair |
| --- | --- | --- |
| P1 | Snapshot bootstrap and stream cursor ownership were ambiguous, including restoring results from a previous Mac. | Pair/sender-scoped cursors; snapshot watermark and completion transaction; staged interrupted transfers; provenance-preserving historical-result restore; no rerun of satisfied jobs. |
| P1 | A job could read inconsistent context across MCP calls while sync was changing the mirror. | One temporary read-only SQLite snapshot per job, captured watermark/prerequisite revisions, cleanup, and current prerequisite checks before phone acceptance. |
| P1 | Phone cancellation/retry commands and Mac execution status shared unclear ownership. | Phone-owned request generation and cancellation intent; Mac-owned execution events echo the generation; late results/status cannot override cancellation or a newer retry. |
| P2 | Pausing analysis offline could misleadingly imply the Mac immediately stops already received jobs. | Local submission gate, versioned pause/cancellation sync, pending acknowledgment status, and an immediate Mac-side pause control. |
| P2 | HealthKit IDs cannot automatically identify equivalent manually logged workouts. | Separately labeled activity/training totals, no timestamp deduplication, stable import IDs, and explicit daily weight source precedence. |
| P2 | HealthKit background callbacks lacked an explicit completion lifecycle. | Register at launch, complete local ingestion/outbox transaction, call completion promptly, and keep LAN/Codex work outside the callback. |

The user confirmed that local storage/sync with hosted Codex model access is acceptable. The user also confirmed that simplicity must preserve the full requested product scope; the plan's stages cover the whole system.

## Remaining implementation evidence

TLS-PSK declarations exist in the installed Apple SDK, and the installed Codex protocol/config exposes the relevant integration controls. These are feasibility observations only. The implementation must still prove a real authenticated TLS exchange, inspect effective Codex tool isolation, build both apps and the helper, and exercise the end-to-end flow. Real-device, signing, background execution, and live-model evidence must be labeled according to what was actually run.

No GitHub comment or review was posted. The review is a local planning artifact, not production certification.

## Watch companion amendment

The user subsequently requested a modest watchOS companion. The same independent reviewer assessed the bounded addition and passed it with two small amendments, both incorporated into the plan:

1. Preserve valid offline set logs against their original program/session revision even if the current program changes. Retain invalid/deleted-session command data with a visible terminal error rather than silently dropping it or retrying forever.
2. Include idempotent session completion after preceding start/set commands have committed, so a Watch-created workout has a complete lifecycle.

The accepted scope is cached workout display and start/set/finish capture through WatchConnectivity. The phone remains the canonical store and Mac/Codex bridge. No separate live HealthKit workout engine or additional backend was introduced. Physical paired-Watch transfer/background testing remains separately labeled.
