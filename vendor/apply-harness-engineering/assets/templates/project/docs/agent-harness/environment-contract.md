# Agent Environment Contract

Describe how an agent can run, inspect, reset, and clean up this project without colliding with other work. Record only commands that have been exercised or label them `candidate`/`blocked`.

## Isolation model

| Concern | Contract | Evidence |
| --- | --- | --- |
| Workspace isolation | <!-- TODO(harness): worktree/container/single workspace plus collision controls --> | <!-- observed proof --> |
| Dependency/cache isolation | <!-- TODO(harness): shared or isolated paths and safety constraints --> | <!-- observed proof --> |
| Port/process allocation | <!-- TODO(harness): deterministic allocation or N/A --> | <!-- observed proof --> |
| Data/state isolation | <!-- TODO(harness): database, fixtures, queues, files, or N/A --> | <!-- observed proof --> |
| Artifact and log location | <!-- TODO(harness): repository-relative or task-local paths --> | <!-- observed proof --> |

## Lifecycle commands

| Stage | Exact command | Expected signal | Safe retry or cleanup | Status |
| --- | --- | --- | --- | --- |
| Setup | <!-- TODO(harness) --> | <!-- expected output/state --> | <!-- recovery --> | <!-- verified/candidate/blocked/N/A --> |
| Start | <!-- TODO(harness) --> | <!-- URL/process/health --> | <!-- recovery --> | <!-- status --> |
| Seed or reproduce | <!-- TODO(harness) --> | <!-- fixture/behavior --> | <!-- recovery --> | <!-- status --> |
| Reset | <!-- TODO(harness) --> | <!-- clean state --> | <!-- recovery --> | <!-- status --> |
| Stop and teardown | <!-- TODO(harness) --> | <!-- process/state removed --> | <!-- recovery --> | <!-- status --> |

## Agent-readable surfaces

| Surface | Access path | Useful queries or actions | Expected evidence | Status |
| --- | --- | --- | --- | --- |
| UI/DOM or accessibility tree | <!-- TODO(harness): browser/simulator/tool or N/A --> | <!-- navigation/inspection --> | <!-- screenshot/video/state --> | <!-- status --> |
| API/CLI behavior | <!-- TODO(harness) --> | <!-- request/invocation --> | <!-- response/exit/output --> | <!-- status --> |
| Logs | <!-- TODO(harness): path/query or N/A --> | <!-- structured filters --> | <!-- correlated event --> | <!-- status --> |
| Metrics | <!-- TODO(harness): endpoint/query or N/A --> | <!-- threshold/query --> | <!-- measured result --> | <!-- status --> |
| Traces | <!-- TODO(harness): endpoint/query or N/A --> | <!-- trace lookup --> | <!-- correlated path --> | <!-- status --> |

## Concurrency and cleanup

<!-- TODO(harness): State how parallel agents avoid shared-state collisions and how leftover processes, browsers, ports, worktrees, containers, test data, and temporary artifacts are detected and cleaned safely. -->

Use the project's native environment and telemetry when possible. Do not install a browser-control or observability stack solely to imitate another repository.
