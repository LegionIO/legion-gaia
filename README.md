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
│ Slack                │     │ 37 cognitive phases        │     │ OutputRouter         │
│ HTTP /api/gaia/ingest│     │ (16 active · 21 dream)     │     │ ChannelAdapter#deliver│
└──────────────────────┘     └────────────────────────────┘     └──────────────────────┘
   translate inbound  ───▶   ingest · tick · think · decide   ───▶   gate · render · deliver
```

> Channel adapters are thin — they translate format and delivery semantics only. All cognitive
> interpretation happens downstream in the tick pipeline. Disable any channel at any time; the mind
> keeps ticking.

### Highlights

- 🧠 **Continuous cognition.** A 1-second heartbeat drains the sensory buffer and runs a full tick through `lex-tick`, so the agent is always thinking — not just request/response.
- 🔌 **Channel abstraction.** CLI, Microsoft Teams, and Slack share one `ChannelAdapter` contract; the cognitive core never knows which interface it is talking to.
- 🌙 **Active *and* dream cycles.** 16 active-tick phases (sensory → emotion → memory → action) plus 21 dream-cycle phases (memory audit, association walk, creativity, metacognition, global workspace) run through one weighted pipeline.
- 🛡️ **Notification gating.** Outbound frames pass schedule (quiet hours) → presence (Teams status) → behavioral (arousal/idle) evaluators before delivery; urgent priority bypasses the gate.
- 🛰️ **Hub-and-spoke router mode.** Keep channel-facing ingress on a public router while private agents do the cognitive work, relayed over Legion transport with worker allowlists.
- 🕊️ **Graceful quiescence.** Shutdown blocks new heartbeats, drains in-flight work, and skips phase handlers cleanly so late tick work never writes into closed services.

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

- `status`: `completed`, `skipped`, or `failed`
- `elapsed_ms`: monotonic elapsed time in milliseconds

Those fields feed `/api/gaia/ticks` for operator-facing tick-stream observability — every event
should have a non-null `status` and `elapsed_ms`.

## The Mechanics, From Source

GAIA itself does not implement learning — it schedules and wires the extensions that do. The
formulas below live in the sibling gems GAIA coordinates, and are cited here so the claims can be
checked against source rather than taken on faith.

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

- 16 full-active phases, 10 dream phases.
- 4 modes with fixed time budgets: `dormant` 0.2s, `sentinel` 0.5s, `full` and `dream` 5.0s each.
- Tick history is an **in-memory, 200-entry ring buffer** recording `{ timestamp, phase, duration_ms,
  status }` per phase. This is not database-persisted — restart the process and it is gone.

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
| `Legion::Gaia.ingest(input_frame)` | Push an `InputFrame` into the sensory buffer. Returns `{ ingested:, buffer_depth:, session_id: }`. |
| `Legion::Gaia.heartbeat` | Drain the buffer and execute one cognitive tick. Returns the tick result hash. |
| `Legion::Gaia.respond(content:, channel_id:, ...)` | Build an `OutputFrame` and route it through the output pipeline. |
| `Legion::Gaia.status` | Runtime + UI state for status/observability tooling. |
| `Legion::Gaia.tick_history` | Ring buffer of recent phase events. |
| `Legion::Gaia.shutdown` | Quiesce and tear down the runtime. |
| `Legion::Gaia.started?` / `shutting_down?` | Lifecycle predicates. |

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
    memory_skip_threshold: 0.8
```

`connected` is managed by GAIA at boot and shutdown. Set `router.mode` to `true` on private agent
processes that should publish through a central router; boot the public router with
`Legion::Gaia.boot(mode: :router)`.

## Cognitive Phases

GAIA wires two phase groups through `PhaseWiring::PHASE_MAP` — 37 phases in total (16 active-tick,
21 dream-cycle). Each entry maps a phase name to an extension runner and method; phases whose runner
extension is not loaded are skipped, and the rest are wired into the tick pipeline.

**Active tick (16):** sensory processing, emotional evaluation, memory retrieval, knowledge
retrieval, identity entropy check, working memory integration, procedural check, prediction engine,
mesh interface, social cognition, theory of mind, gut instinct, action selection, memory
consolidation, homeostasis regulation, and post-tick reflection.

**Dream cycle (21):** memory audit, association walk, contradiction resolution, agenda formation,
curiosity execution, consolidation commit, knowledge promotion, dream reflection, partner
reflection, dream narration, dream cycle, creativity tick, lucid dream, epistemic vigilance,
predictive processing, free energy, metacognition, default mode network, prospective memory, inner
speech, and global workspace.

Phase handlers may skip expensive work when idle or while GAIA is shutting down. Skipped phases still
produce `status` and timing metadata so the tick stream stays complete.

## HTTP API

GAIA registers routes with [`Legion::API`](https://github.com/LegionIO/LegionIO) at boot via
`register_library_routes`. API responses follow the LegionIO envelope shape (`{ data: ... }` /
`{ error: { code:, message: } }`).

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/api/gaia/status` | Runtime + UI state (mode, buffer depth, channels, sessions, tick count, notification gate). |
| `GET`  | `/api/gaia/ticks?limit=50` | Recent phase events; `limit` is clamped to the tick-history ring-buffer size. |
| `GET`  | `/api/gaia/channels` | Active channel adapters and their capabilities. |
| `GET`  | `/api/gaia/buffer` | Sensory buffer depth, emptiness, and max size. |
| `GET`  | `/api/gaia/sessions` | Active session count. |
| `POST` | `/api/gaia/ingest` | Push a normalized content payload into the sensory buffer without a channel adapter. |
| `POST` | `/api/channels/teams/webhook` | Microsoft Teams Bot Framework activity intake (auth-gated when `app_id` is set). |

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
`Legion::Gaia.ingest`. When a Teams `app_id` is configured, requests must carry a bearer token; GAIA
validates JWT claims and verifies the signature against Bot Framework signing keys before translating
or ingesting. Missing or invalid authorization returns `401`.

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
| Teams | Bot Framework activity ingestion and proactive delivery | Validates bearer tokens when `app_id` is set. |
| Slack | Slack-style rich text and threaded delivery | HMAC-SHA256 signing verification. |

Adapters translate format and delivery semantics only. Cognitive interpretation happens downstream in
the tick pipeline, so adapters stay thin, stateless, and recreatable without loss.

## Notification Gate

The notification gate evaluates outbound frames before delivery, in order:

1. `ScheduleEvaluator` — checks configured quiet-hour windows.
2. `PresenceEvaluator` — maps Teams presence to a minimum delivery priority.
3. `BehavioralEvaluator` — scores arousal and idle signals into a delivery-likelihood value.

Urgent or critical frames bypass quiet-hour delays through `priority_override`. Delayed frames are
stored in a bounded `DelayQueue` and re-evaluated each heartbeat.

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

`shutdown.heartbeat_wait_timeout` bounds how long shutdown waits for in-flight heartbeat work before
logging a warning and continuing; `shutdown.heartbeat_wait_log_interval` controls wait-progress logs.
This keeps routine shutdown from producing late writes to closed data/logging resources while
avoiding an indefinite hang if a heartbeat blocks inside extension work.

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
bundle exec rspec    # 0 failures required before commit
bundle exec rubocop  # 0 offenses required
```

The build artifact (`*.gem`) is not the source of truth; release tooling builds it from the version
in `lib/legion/gaia/version.rb`.

## License

Apache-2.0
