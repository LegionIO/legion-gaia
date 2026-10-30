<h1 align="center">Legion::Gaia</h1>

GAIA is the coordination layer for LegionIO's experimental agentic extensions. It turns channel
input, extension runners, memory, notification policy, and router transport into one continuously
ticking agent runtime. The layer is research: the open question is whether a job engine improves
when successful task-routes strengthen and unused ones decay. GAIA is optional — the core LegionIO
job engine runs without it, and none of its cognitive mechanics activate unless it is installed.

<p align="center">
  A <b>cognitive coordination layer</b> for the LegionIO framework — a continuously ticking agent
  runtime that drains channel input into a sensory buffer, runs it through a weighted pipeline of
  agentic cognitive phases, and routes responses back out through schedule, presence, and behavioral
  notification gates. One mind, many interfaces (CLI, Microsoft Teams, Slack), one heartbeat.
</p>

<p align="center">
  <img alt="Gem Version" src="https://img.shields.io/gem/v/legion-gaia.svg?color=CC342D">
  <img alt="Ruby" src="https://img.shields.io/badge/ruby-3.4%2B-CC342D.svg">
  <img alt="License" src="https://img.shields.io/badge/license-Apache--2.0-blue.svg">
</p>

```text
┌──────────────────────┐     ┌────────────────────────────┐     ┌──────────────────────┐
│ CHANNELS · any client│     │ COGNITIVE CORE             │     │ DELIVERY · any client│
├──────────────────────┤     ├────────────────────────────┤     ├──────────────────────┤
│ CLI                  │     │ SensoryBuffer              │     │ ChannelAwareRenderer │
│ Microsoft Teams      │ ──▶ │ Heartbeat → lex-tick       │ ──▶ │ NotificationGate     │
│ Slack                │     │ Scoped phase handlers      │     │ OutputRouter         │
│ HTTP /api/gaia/ingest│     │ Explicit optional groups   │     │ ChannelAdapter#deliver│
└──────────────────────┘     └────────────────────────────┘     └──────────────────────┘
   translate inbound  ───▶   ingest · tick · think · decide   ───▶   gate · render · deliver
```

> Channel adapters are thin — they translate format and delivery semantics only. All cognitive
> interpretation happens downstream in the tick pipeline. Disable any channel at any time; the mind
> keeps ticking.

### Highlights

- **Bounded cognition.** A heartbeat drains one identity/conversation at a time under the existing tick budget.
- **Channel abstraction.** CLI, Microsoft Teams, and Slack share a channel contract while retaining exact authenticated owners and destinations.
- **Explicit activation.** Default active/dream schedules remain unchanged; workspace and metacognition require opt-in and supporting providers.
- **Notification gating.** Quiet hours, presence, and behavioral gates precede delivery. Priority never bypasses a consent or termination barrier.
- **Hub-and-spoke router mode.** Public ingress can relay to private agents through existing Legion transport and worker allowlists.
- **Graceful quiescence.** New work stops before teardown; an over-time heartbeat defers finalization instead of losing its live state.

## What GAIA Does

GAIA turns channel input, extension runners, memory, notification policy, and router transport into
one continuously ticking agent runtime:

- Boots the cognitive runtime, discovers available agentic extensions, and wires phase handlers.
- Drains inbound CLI, Microsoft Teams, Slack, and API input into a bounded sensory buffer.
- Runs active-tick and dream-cycle phase pipelines through [`lex-tick`](https://github.com/LegionIO/LegionIO).
- Normalizes every phase result with stable `status` and `elapsed_ms` metadata for UI and logs.
- Routes responses locally or through a hub-and-spoke GAIA router.
- Applies schedule, presence, and behavioral notification gates before delivery.
- Tracks sessions, partner observations, tick history, and status for operator-facing tooling.
- Quiesces cleanly during shutdown so late heartbeat work does not write into closed services.

## How It Works

```text
Channel input
  -> ChannelAdapter#translate_inbound
  -> InputFrame
  -> Legion::Gaia.ingest
  -> SensoryBuffer
  -> Heartbeat (every ~1s)
  -> lex-tick orchestrator
  -> PhaseWiring handlers
  -> agentic extension runners
  -> OutputRouter
  -> NotificationGate
  -> ChannelAdapter#deliver
```

The registry resolves runners from the loaded LegionIO extension set and builds phase handlers. Each
phase handler annotates its result with:

- `status`: truthful `completed`, `skipped`, `failed`, `partial`, `deferred`, or `unavailable`; history also exposes missing handlers and budget skips
- `elapsed_ms`: monotonic elapsed time in milliseconds

Those fields feed `/api/gaia/ticks` for operator-facing tick-stream observability — every event
should have a non-null `status` and `elapsed_ms`.

## The Mechanics, From Source

GAIA coordinates extension learning and owns scoped relationship/response attribution. The
formulas below describe specific mechanisms, not evidence that a proposed action succeeded.
Confidence and bond strength never grant permission.

**Connection reinforcement — [`lex-synapse`](https://github.com/LegionIO/lex-synapse):**

- Connection confidence: `+0.02` per success, `-0.05` per failure, `-0.03` per validation failure.
- Consecutive-success bonus: `+0.05` after 50 consecutive successes.
- Idle decay: `confidence * 0.998^hours`.
- Autonomy ladder, driven by confidence: `observe` 0.0–0.3, `filter` 0.3–0.6, `transform` 0.6–0.8,
  `autonomous` 0.8–1.0.
- Auto-revert: after exactly 3 consecutive failures, the mutation's recorded `before_state` is
  restored automatically.

**Knowledge confidence — two tiers, two gems:**

Apollo knowledge is split across a local per-node store and a shared cross-node store, and the two
have different confidence constants. Do not conflate them.

- Local store — [`legion-apollo`](https://github.com/LegionIO/legion-apollo)
  (`lib/legion/apollo/helpers/confidence.rb`): new knowledge starts at confidence `0.5`,
  corroboration adds `+0.15`, decay rate is `0.005`, entries archive below confidence `0.1`.
  Lifecycle: `pending` -> `confirmed` -> `disputed` -> `deprecated` -> `archived`.
- Shared store — [`lex-apollo`](https://github.com/LegionIO/lex-apollo)
  (`lib/legion/extensions/apollo/helpers/confidence.rb`): new knowledge starts at confidence `0.5`,
  corroboration adds `+0.3 * weight` when a `>= 0.9` cosine-similar entry arrives from a *different*
  provider (weight is halved for a same-provider match), retrieval adds `+0.02`, power-law time
  decay begins after 168 hours of inactivity, and entries archive below confidence `0.05`.
  Lifecycle: `candidate` -> `confirmed` -> `disputed` -> `decayed` -> `archived`.

**Tick scheduling — `lex-tick` constants:**

- Default schedules: 16 full-active phases and 10 dream phases (identity entropy is shared).
- Four modes and existing budgets: `dormant` 0.2s, `sentinel` 0.5s, `full_active` and `dormant_active` 5.0s.
- The budget is checked between handlers; a blocking handler is not preempted. Optional work receives no extra budget.
- Tick history is an in-memory, 200-entry ring buffer with identity/conversation/exchange ownership.
  It records scheduled, missing, deferred, failed, and budget-skipped work; it does not survive restart.

## Measured, From the Maintainer's Development Instance

The numbers below come from the maintainer's long-running development instance of the framework,
not a benchmark suite. Date windows and provenance are stated next to each figure; treat this as
evidence from a single running instance, not a generalizable result.

**A reinforcement-learning receipt.** A GAIA advisory weight learned from `0.5` to `0.535` across
scored reaction events, recorded in a timestamped ledger entry. This is the smallest verifiable
unit of "the layer learned something" available today.

**Maintainer's development instance (83 days, 2026-04-10 to 2026-07-02):**

- 133,585 memory traces, every one decayed at least once.
- 3,407 reinforced.
- Maximum reinforcement count on a single trace: 37.

**A note on contradiction weights.** Contradiction links carry a *fixed* assigned weight of `0.8` —
this is a flag for downstream resolution, not a learned value. Do not read it as evidence of
learning. The learned variance lives in the 0.5 -> 0.535 advisory weight artifact above.

## The Loop With the LLM Layer

GAIA's own retrieval lands in tick context and executive goal formation — it does not touch LLM
requests directly. Injection of Apollo knowledge into LLM requests happens in `legion-llm`'s
pipeline, via the `rag_context` and `gaia_advisory` steps: the pipeline pulls context, GAIA advises
on it. GAIA does not inject prompts itself.

## Honest Boundaries

- All measured numbers above come from the maintainer's own development instance, not a benchmark
  suite and not any operational deployment — treat them as evidence from one running instance, not
  a general claim about the approach.
- Some mechanisms have code but no accumulated data yet: the entity-relationship graph tables are
  empty in the measured instance, and mind-growth proposals persist only to a 7-day cache TTL, so
  there is no long-horizon record of them yet.
- Tick history is in-memory only (see the 200-entry ring buffer above) — it does not survive a
  restart, and there is currently no persisted long-run tick record.
- Whether this coordination layer earns its keep — whether reinforcement and decay measurably
  improve routing over the plain job engine — is an open research question.

## Installation

```ruby
gem 'legion-gaia'
```

`legion-gaia` depends on the core LegionIO libraries plus the agentic extension set used by the
cognitive pipeline. The tick orchestrator (`lex-tick`) is required — GAIA is inoperable without it.
The full active and dream cycles additionally require the consolidated `lex-agentic-*` cognitive
domain gems and operational extensions such as `lex-mesh`, `lex-synapse`, `lex-detect`, and
`lex-coldstart`. Channel-specific delivery depends on the matching extension (for example
`lex-microsoft_teams` or `lex-slack`).

### Provider compatibility and activation

| Provider | Supported behavior |
|----------|--------------------|
| `legion-apollo >= 0.5.13` | Required. Earlier changed-content FTS updates can break durable GAIA snapshots. |
| `lex-agentic-memory 0.1.41` | Verified existing audit, association, episodic correction, and Gut consumption APIs; no new memory release is required for these handoffs. |
| `lex-tick 0.1.17` | Default schedules remain usable; optional groups report unsupported. |
| `lex-tick >= 0.1.18` | Explicit `global_workspace` / `metacognition` scheduling. Capability detection requires the actual keyword contract, not a catch-all `**kwargs`. |
| `lex-agentic-social 0.1.21` | Explicit corrections remain effective; scoped calibration is unavailable and never falls back to shared/latest-response state. |
| `lex-agentic-social >= 0.2.0` | Scoped calibration receipts, weights, and restoration when the explicit identity APIs are available. |
| `lex-agentic-inference 0.1.11` | Existing identity-aware generation/resolution APIs support verifiable predictions; no newer inference release is required. Providers missing those contracts remain unavailable. |

New tick/social versions are optional capability prerequisites, not permission to deploy unpublished
branches. Leave their capabilities unavailable until their independent releases are installed.
Published-provider and candidate-package combinations are exercised separately.
Existing LLM callers that do not return applied source IDs remain ungraded; GAIA does not fabricate
delivery acknowledgments or require a coordinated LLM upgrade.

## Basic Usage

```ruby
require 'legion/gaia'

Legion::Gaia.boot

adapter = Legion::Gaia.channel_registry.adapter_for(:cli)
frame   = adapter.translate_inbound('hello')
Legion::Gaia.ingest(frame)

tick = Legion::Gaia.heartbeat
Legion::Gaia.respond(content: 'ack', channel_id: :cli)

status = Legion::Gaia.status
events = Legion::Gaia.tick_history.recent(limit: 10)

Legion::Gaia.shutdown
```

### Public API

| Method | Description |
|--------|-------------|
| `Legion::Gaia.boot(mode: nil)` | Boot the runtime. `mode: :router` boots channels only (hub-and-spoke router). |
| `Legion::Gaia.ingest(input_frame)` | Accept trusted input; return `{ ingested:, buffer_depth:, session_id:, exchange_id: }` and any explicit `cognitive_outcome`. Rejections include a reason. |
| `Legion::Gaia.heartbeat` | Drain one scoped batch and execute one budgeted tick. Includes `phases_scheduled`, results, and correlation. |
| `Legion::Gaia.respond(content:, channel_id:, ...)` | Preserve the original input owner/destination when replying; apply lifecycle and delivery gates. |
| `Legion::Gaia.status(identity: nil)` | Runtime state, persistence readiness, and scoped demonstrated capabilities. |
| `Legion::Gaia.tick_history.recent(identity:, conversation_id:, limit:)` | Read owner-scoped phase history. Unscoped internal access is administrative, not a human endpoint. |
| `Legion::Gaia.shutdown` | Quiesce; return `{ stopped: false, quiescing: true }` if an active heartbeat must finish before finalization. |
| `Legion::Gaia.started?` / `shutting_down?` | Lifecycle predicates. |
| `Legion::Gaia::Advisory.advise(caller:, conversation_id:, exchange_id:)` | Return proposed adjustments with an advisory ID and selected-source provenance, without claiming application. |
| `Legion::Gaia.record_response_applied(advisory_id:, identity:, applied:)` | Persist a returned/sent/acknowledged receipt for explicitly selected source IDs. |
| `Legion::Gaia::Disclosure.report(identity:)` | Describe the same live/restored state used by behavior and the actual privacy/deletion boundaries. |
| `Legion::Gaia::DeathProtocol.terminate_bond(identity:, confirm: true)` | Persist the barrier before erasure and return per-store acknowledgments; partial failure remains blocked and retryable. |

## Configuration

GAIA reads `Legion::Settings[:gaia]` when present and deep-merges it over
`Legion::Gaia::Settings.default`.

```yaml
gaia:
  enabled: true
  heartbeat_interval: 1
  connected: false           # managed by GAIA at boot/shutdown
  shutdown:
    heartbeat_wait_timeout: 30.0
    heartbeat_wait_log_interval: 5.0
  tick:
    enabled_optional_phases: []  # opt in one verified group at a time
  channels:
    cli:
      enabled: true
    teams:
      enabled: false
      app_id: null
      default_conversation_id: null
    slack:
      enabled: false
  notifications:
    enabled: true
    quiet_hours:
      enabled: true
      schedule:
        - days: [mon, tue, wed, thu, fri]
          start: "21:00"
          end: "07:00"
          timezone: America/Chicago
    priority_override: urgent
    delay_queue_max: 100
    max_delay: 14400
  router:
    mode: false
    worker_id: null
    allowed_worker_ids: []
  session:
    persistence: auto
    ttl: 86400
  output:
    mobile_max_length: 500
    suggest_channel_switch: true
  knowledge:
    retrieval_limit: 5
    retrieval_min_confidence: 0.3
    memory_retrieval_limit: 10
    memory_audit_limit: 20
```

`connected` is managed by GAIA at boot and shutdown. Set `router.mode` to `true` on private agent
processes that should publish through a central router; boot the public router with
`Legion::Gaia.boot(mode: :router)`.

## Cognitive Phases

The default full-active schedule has 16 phases; the dream schedule has 10, including the shared
identity-entropy phase. Discovery does not activate extra work. Missing handlers remain visible.

**Full active:** sensory processing, emotional evaluation, memory retrieval, knowledge retrieval,
identity entropy, working memory integration, procedural check, prediction, mesh interface, social
cognition, theory of mind, gut instinct, action selection, memory consolidation, homeostasis,
and post-tick reflection.

**Dream:** memory audit, association walk, contradiction resolution, identity entropy, agenda
formation, consolidation commit, knowledge promotion, dream reflection, partner reflection,
and dream narration.

**Optional full-active groups:**

| Group | Placement and prerequisite | Observable consumer |
|-------|----------------------------|---------------------|
| `global_workspace` | After gut instinct; requires meaningful sensory processing and correlated candidates | The selected signal/memory changes executive drives and intention formation. |
| `metacognition` | After meaningful post-tick reflection | Current demonstrated assessments update scoped capability readiness/history; loaded constants are only inventory. |

Opt in with `gaia.tick.enabled_optional_phases: [global_workspace]` or `[metacognition]`.
Both default to off. Failed prerequisites defer the group; unavailable providers do not produce
success-shaped placeholders. `status(identity:)[:capabilities]` reports readiness, ownership,
the latest observed status/reason, and the last meaningful outcome/time. A later budget skip
does not erase earlier evidence or continue claiming current readiness.

Other former extra mappings retain their actual owners:

| Work | Owner |
|------|-------|
| Curiosity execution, dream-cycle orchestration, creativity tick, default-mode thought | Existing background actors |
| Lucid dream, epistemic vigilance, inner speech | Explicit requests with real content and consumers |
| Predictive processing, free energy, prospective memory | Existing events with real observations, beliefs, or intentions |

Memory decay and tier migration remain background-owned; their heartbeat placeholders report
`deferred` and do not duplicate maintenance. Prediction/intention creation is a proposal, not
task completion. Technical task completion and human sentiment are not objective outcome evidence.

### Explicit outcome reports

A trusted human `InputFrame` may carry `metadata[:prediction_request]` with a nonblank `domain`,
`description`, and scalar `expected_outcome`. Later authenticated input can report:

```ruby
cognitive_outcome: {
  prediction_id: prediction_id,       # or intention_id, never both
  source_exchange_id: original_exchange_id,
  outcome: :incorrect,               # prediction: correct/incorrect/partial; intention: completed
  actual: false,
  confirmation: 'human_observed'
}
```

GAIA derives the owner from the authenticated frame, checks the generated ID and original exchange,
and labels the evidence `human_confirmation`. A contradictory classification is rejected.
Heuristic predictions, missing IDs, mismatched people/exchanges, and duplicate reports cannot
resolve or reinforce another prediction/intention. No machine execution proof is invented.

## Identity, Feedback, and Recovery

- Trusted principal IDs take precedence. Native Teams IDs include tenant ownership; Slack IDs
  include workspace ownership. Display names and continuity tokens are not identity evidence.
- Input ingestion owns the human observation. Pipeline notifications do not reinforce it again.
- Advice is only a proposal. A delivery receipt must name selected behavioral/trace/adjustment
  IDs and a `returned`, `sent`, or `acknowledged` delivery outcome before feedback can grade it.
- Feedback must agree with all supplied identity, conversation, response-exchange, advisory, and
  reply references. There is no global/latest-response fallback.
- Explicit corrected constraints outrank inferred preferences in the matching scope. Generic
  rejection vetoes the rejected sources; it neither invents a preference nor crystallizes the
  rejected directive.
- Private snapshots use exact identity tags and are stored through Apollo Local. Lifecycle barriers
  and response claims/acknowledgments are synchronous. Ordinary bond/behavior changes can lose up
  to the existing 300-second flush interval on abrupt process loss; graceful shutdown flushes them.
- A persisted but interrupted feedback claim remains uncertain and is not automatically replayed.
  Durable explicit correction evidence still constrains future behavior.
- Missing/unreadable lifecycle storage fails closed for private identities. Anonymous/core operation
  stays available. Recovery retries are bounded; no shared-store fallback is used.
- Termination removes acknowledged owned snapshots, FTS/source links, live memories where supported,
  sessions, pending outputs, and attribution. Its minimal barrier survives restart; partial erasure
  is retried. Disclosure distinguishes local storage from deployment-dependent external processing.

Before adoption, quiesce writers and retain the previous resolved configuration. Older GAIA
versions do not honor these lifecycle barriers: rollback to them is unsafe. Disable affected optional
capabilities and forward-fix; never restore a stale snapshot over a correction or revocation.

## HTTP API

GAIA registers routes with [`Legion::API`](https://github.com/LegionIO/LegionIO) at boot via
`register_library_routes`. API responses follow the LegionIO envelope shape (`{ data: ... }` /
`{ error: { code:, message: } }`).

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/api/gaia/status` | Runtime/persistence state and the authenticated owner's demonstrated capabilities. |
| `GET`  | `/api/gaia/ticks?limit=50` | Requires authentication; returns only that owner's phase history. |
| `GET`  | `/api/gaia/channels` | Active channel adapters and their capabilities. |
| `GET`  | `/api/gaia/buffer` | Sensory buffer depth, emptiness, and max size. |
| `GET`  | `/api/gaia/sessions` | Active session count. |
| `POST` | `/api/gaia/ingest` | Normalize input using trusted request auth, not a body-supplied identity; rejected input returns `409`. |
| `POST` | `/api/channels/teams/webhook` | Requires configured application authentication and a verified Bot Framework bearer token. |
| `GET` | `/api/gaia/partner/:identity/report` | Authenticated-owner disclosure only. |
| `DELETE` | `/api/gaia/bond/:identity` | Authenticated-owner termination with explicit confirmation. |

### `GET /api/gaia/status`

```json
{
  "started": true,
  "mode": "agent",
  "buffer_depth": 0,
  "active_channels": ["cli"],
  "sessions": 1,
  "tick_count": 42,
  "tick_mode": "dormant",
  "sensory_buffer": { "depth": 0, "max_capacity": 1000 },
  "sessions_detail": { "active_count": 1, "ttl": 86400 },
  "notification_gate": { "schedule": true, "presence": "Available", "behavioral": 0.84 },
  "uptime_seconds": 120
}
```

`notification_gate.schedule` is `true` when the current schedule is open for delivery. `presence` is
the last known Teams presence value when available. `behavioral` is the current 0.0–1.0
delivery-likelihood score.

### `POST /api/channels/teams/webhook`

Accepts Microsoft Teams Bot Framework activities. The route delegates to
`Legion::Gaia::Channels::Teams::WebhookHandler`, then ingests translated message activities through
`Legion::Gaia.ingest`. A configured Teams `app_id` and bearer token are required; GAIA
validates JWT claims and verifies the signature against Bot Framework signing keys before translating
or ingesting. Missing configuration or invalid authorization returns `401`.

Non-message activities are intentionally acknowledged without entering cognition:

| Activity | Behavior |
|----------|----------|
| `message` | Translated to an `InputFrame` and ingested. |
| `conversationUpdate` | Stored for proactive delivery and acknowledged. |
| `invoke` | Acknowledged for Bot Framework compatibility. |
| Other activity types | Acknowledged and ignored. |

## Channel Adapters

| Adapter | Purpose | Notes |
|---------|---------|-------|
| CLI | Local text interaction | Built in, enabled by default. |
| Teams | Bot Framework activity ingestion and proactive delivery | Requires application authentication; preserves exact tenant/user/conversation ownership. |
| Slack | Slack-style rich text and threaded delivery | HMAC-SHA256 signing verification. |

Adapters translate format and delivery semantics. Teams delivery requires the intended tenant and
conversation; proactive lookup matches the target user instead of borrowing another conversation in
the tenant. An explicit Slack destination cannot fall back to a default webhook. Received timestamps,
owners, destinations, and correlation survive router serialization.

## Notification Gate

The notification gate evaluates outbound frames before delivery, in order:

1. `ScheduleEvaluator` — checks configured quiet-hour windows.
2. `PresenceEvaluator` — maps Teams presence to a minimum delivery priority.
3. `BehavioralEvaluator` — scores arousal and idle signals into a delivery-likelihood value.

Urgent or critical frames bypass quiet-hour delays through `priority_override`, but never bypass
revocation/termination. Delayed frames remain scoped and bounded; lifecycle is checked again at
final delivery and terminated identities' queued frames are removed.

## Router Mode

GAIA supports hub-and-spoke deployments where a public router relays traffic to private agents over
Legion transport. Channel-facing ingress stays on the public side while private agents do the
cognitive work.

```ruby
# Public router process
Legion::Gaia.boot(mode: :router)

# Agent process with router.worker_id configured
Legion::Gaia.boot
```

Router allowlists are enforced for both live registrations and DB-backed worker resolution. If
`allowed_worker_ids` is empty, any active worker may be routed; otherwise only listed workers are
eligible.

```text
Channel client -> GAIA router -> Legion transport -> GAIA agent
              -> Legion transport -> GAIA router -> channel client
```

## Shutdown Semantics

`Legion::Gaia.shutdown` marks the runtime as quiescing before tearing down components:

1. New heartbeats are blocked.
2. Active heartbeat work is allowed to drain.
3. Phase handlers return `{ status: :skipped, reason: :gaia_shutting_down }` once shutdown starts.
4. Trackers and channel/router bridges are flushed or stopped.
5. Runtime references are cleared.

`shutdown.heartbeat_wait_timeout` bounds the caller's wait. If a heartbeat is still running, shutdown
returns `quiescing: true`, leaves its resources intact, and rejects reboot/new work. The last active
heartbeat performs final teardown after leaving the shared write lock.
`shutdown.heartbeat_wait_log_interval` controls wait-progress logs. Operators must not close shared
data/logging services while GAIA still reports quiescing.

## Integration with LegionIO

GAIA is a core gem in the [LegionIO](https://github.com/LegionIO/LegionIO) startup sequence, booted
between Apollo and supervision. It registers its routes with `Legion::API` and persists tracker and
bond state through [`legion-apollo`](https://github.com/LegionIO/legion-apollo) (the knowledge/memory
store) when Apollo Local is available.

Sibling gems referenced above:

- [`legion-apollo`](https://github.com/LegionIO/legion-apollo) — knowledge and memory store; GAIA hydrates trackers and the bond registry from it.
- [`legion-settings`](https://github.com/LegionIO/legion-settings) — configuration loading and defaults.
- [`legion-logging`](https://github.com/LegionIO/legion-logging) — structured logging.

## Development

```bash
bundle install
bundle exec rubocop -A
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
```

Require a clean whole-repo lint pass and full-suite exit status after the last Ruby edit. Keep RSpec
stdout quiet; inspect only extracted failed examples when it fails. Package acceptance must use
installed gem artifacts, not sibling path overrides. Release scenarios cover real memory/association,
correction-to-next-context, two-human/conversation isolation, interrupted feedback claims, SQLite/FTS
termination, and independently opted-in workspace/metacognition with supporting provider artifacts.

The build artifact (`*.gem`) is not the source of truth; release tooling builds it from the version
in `lib/legion/gaia/version.rb`.

## License

Apache-2.0
