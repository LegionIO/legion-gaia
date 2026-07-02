# Legion::Gaia

GAIA is the coordination layer for LegionIO's experimental agentic extensions. It turns channel
input, extension runners, memory, notification policy, and router transport into one continuously
ticking agent runtime. The layer is research: the open question is whether a job engine improves
when successful task-routes strengthen and unused ones decay. GAIA is optional — the core LegionIO
job engine runs without it, and none of its cognitive mechanics activate unless it is installed.

**Version:** 0.9.50

## What GAIA Does

- Boots the cognitive runtime, discovers available agentic extensions, and wires phase handlers.
- Drains inbound CLI, Microsoft Teams, Slack, and API input into a bounded sensory buffer.
- Runs active tick and dream-cycle phase pipelines through `lex-tick`.
- Normalizes phase results with stable `status` and `elapsed_ms` metadata for UI and logs.
- Routes responses locally or through a hub-and-spoke GAIA router.
- Applies schedule, presence, and behavioral notification gates before delivery.
- Tracks sessions, partner observations, tick history, and status for Interlink.
- Quiesces cleanly during shutdown so late heartbeat work does not write into closed services.

## Runtime Shape

```text
Channel input
  -> ChannelAdapter
  -> InputFrame
  -> Legion::Gaia.ingest
  -> SensoryBuffer
  -> Heartbeat
  -> lex-tick Orchestrator
  -> PhaseWiring handlers
  -> agentic extension runners
  -> OutputRouter
  -> NotificationGate
  -> ChannelAdapter delivery
```

The registry resolves runners from the loaded LegionIO extension set and builds phase handlers. Phase handlers annotate each phase result with:

- `status`: `completed`, `skipped`, or `failed`
- `elapsed_ms`: monotonic elapsed time in milliseconds

Those fields feed `/api/gaia/ticks` for operator-facing tick stream observability.

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

## Measured, From a Production Deployment

The numbers below come from one production deployment of the framework, not a benchmark suite.
Date windows and provenance are stated next to each figure; treat this as evidence from a single
running instance, not a generalizable result.

**A reinforcement-learning receipt.** A GAIA advisory weight learned from `0.5` to `0.535` across
scored reaction events, recorded in a timestamped ledger entry. This is the smallest verifiable
unit of "the layer learned something" available today.

**Production Postgres (window 2026-03-26 to 2026-05-30):**

| Memory type | Traces |
|---|---|
| Episodic | 4,181,871 |
| Semantic | 76,088 |
| Sensory | 2,557 |
| Identity | 2,554 |
| Procedural | 1,818 |
| **Total** | **4,262,888** |

- 2,897,670 memory co-activation pairs.
- 53,686 contradictions detected and linked.
- 208 similarity relations with learned weight variance (range 0.900–0.99996, average 0.926).
- 33,862 identity resolutions: 16,972 Entra-verified, 16,890 cache-served, 217 unverified, 65
  canonical changes.

**Local SQLite (83 days, 2026-04-10 to 2026-07-02):**

- 133,585 traces, every one decayed at least once.
- 3,407 reinforced.
- Maximum reinforcement count on a single trace: 37.

**A note on contradiction weights.** Contradiction links carry a *fixed* assigned weight of `0.8` —
this is a flag for downstream resolution, not a learned value. Do not read it as evidence of
learning. The learned variance lives in the similarity relations above (0.900–0.99996) and in the
0.5 -> 0.535 advisory weight artifact.

## The Loop With the LLM Layer

GAIA's own retrieval lands in tick context and executive goal formation — it does not touch LLM
requests directly. Injection of Apollo knowledge into LLM requests happens in `legion-llm`'s
pipeline, via the `rag_context` and `gaia_advisory` steps: the pipeline pulls context, GAIA advises
on it. GAIA does not inject prompts itself.

## Honest Boundaries

- All measured numbers above come from a single production deployment, not a benchmark suite —
  treat them as evidence from one running instance, not a general claim about the approach.
- Some mechanisms have code but no accumulated data yet: the entity-relationship graph tables are
  empty in the measured deployment, and mind-growth proposals persist only to a 7-day cache TTL, so
  there is no long-horizon record of them yet.
- Tick history is in-memory only (see the 200-entry ring buffer above) — it does not survive a
  restart, and there is currently no persisted long-run tick record.
- Whether this coordination layer earns its keep — whether reinforcement and decay measurably
  improve routing over the plain job engine — is an open research question. It is being run in
  production specifically to answer that question, not because the answer is already known.

## Installation

```ruby
gem 'legion-gaia'
```

`legion-gaia` depends on the core LegionIO libraries plus the agentic extension set used by the cognitive pipeline, including `lex-tick`, `legion-apollo`, and the consolidated `lex-agentic-*` gems. Channel-specific delivery depends on the matching extension, such as `lex-microsoft_teams` or `lex-slack`.

## Basic Usage

```ruby
require 'legion/gaia'

Legion::Gaia.boot

adapter = Legion::Gaia.channel_registry.adapter_for(:cli)
frame = adapter.translate_inbound('hello')
Legion::Gaia.ingest(frame)

tick = Legion::Gaia.heartbeat
Legion::Gaia.respond(content: 'ack', channel_id: :cli)

status = Legion::Gaia.status
events = Legion::Gaia.tick_history.recent(limit: 10)

Legion::Gaia.shutdown
```

## Configuration

GAIA reads `Legion::Settings[:gaia]` when available and falls back to `Legion::Gaia::Settings.default`.

```yaml
gaia:
  enabled: true
  heartbeat_interval: 1
  connected: false
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

`connected` is managed by GAIA at boot and shutdown. Set `router.mode` to true on private agent processes that should publish through a central router; boot the public router with `Legion::Gaia.boot(mode: :router)`.

## Cognitive Phases

GAIA wires two phase groups.

**Active tick:** sensory processing, emotional evaluation, memory retrieval, knowledge retrieval, identity entropy check, working memory integration, procedural check, prediction engine, mesh interface, social cognition, theory of mind, gut instinct, action selection, memory consolidation, homeostasis regulation, and post-tick reflection.

**Dream cycle:** memory audit, association walk, contradiction resolution, agenda formation, curiosity execution, consolidation commit, knowledge promotion, dream reflection, partner reflection, dream narration, dream cycle, creativity tick, lucid dream, epistemic vigilance, predictive processing, free energy, metacognition, default mode network, prospective memory, inner speech, and global workspace.

Phase handlers may skip expensive work when idle or while GAIA is shutting down. Skipped phases still produce status and timing metadata so the tick stream remains complete.

## HTTP API

GAIA registers routes with `Legion::API` when available.

### `GET /api/gaia/status`

Returns runtime and UI state:

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
  "notification_gate": {
    "schedule": true,
    "presence": "Available",
    "behavioral": 0.84
  },
  "uptime_seconds": 120
}
```

`notification_gate.schedule` is `true` when the current schedule is open for delivery. `presence` is the last known Teams presence value when available. `behavioral` is the current 0.0 to 1.0 delivery-likelihood score.

### `GET /api/gaia/ticks?limit=50`

Returns recent phase events:

```json
{
  "events": [
    {
      "timestamp": "2026-04-27T21:45:00Z",
      "phase": "memory_retrieval",
      "duration_ms": 3.112,
      "status": "completed"
    }
  ]
}
```

`limit` is clamped to the tick history ring-buffer size.

### `POST /api/channels/teams/webhook`

Accepts Microsoft Teams Bot Framework activities. The route delegates to `Legion::Gaia::Channels::Teams::WebhookHandler`, then ingests translated message activities through `Legion::Gaia.ingest`.

When a Teams `app_id` is configured, requests must include a bearer token. GAIA validates JWT claims and verifies the signature against Bot Framework signing keys before translating or ingesting the activity. Missing or invalid authorization returns `401`.

Non-message Teams activities are intentionally acknowledged without entering cognition:

| Activity | Behavior |
| --- | --- |
| `message` | Translated to an `InputFrame` and ingested. |
| `conversationUpdate` | Stored for proactive delivery and acknowledged. |
| `invoke` | Acknowledged for Bot Framework compatibility. |
| Other activity types | Acknowledged and ignored. |

### `POST /api/gaia/ingest`

Pushes a normalized content payload into the sensory buffer without going through a channel adapter.

## Channel Adapters

| Adapter | Purpose | Notes |
| --- | --- | --- |
| CLI | Local text interaction | Built in and enabled by default. |
| Teams | Bot Framework activity ingestion and proactive delivery | Validates bearer tokens when `app_id` is set. |
| Slack | Slack-style rich text and threaded delivery | Uses the shared channel abstraction. |

Adapters translate format and delivery semantics only. Cognitive interpretation happens downstream in the tick pipeline.

## Notification Gate

The notification gate evaluates outbound frames before delivery:

1. `ScheduleEvaluator` checks configured quiet-hour windows.
2. `PresenceEvaluator` maps Teams presence to minimum delivery priority.
3. `BehavioralEvaluator` scores arousal and idle signals.

Urgent or critical frames can bypass quiet-hour delays through `priority_override`. Delayed frames are stored in a bounded queue and re-evaluated each heartbeat.

## Router Mode

GAIA supports hub-and-spoke deployments where a public router relays traffic to private agents over Legion transport. This keeps channel-facing ingress on the public side while private agents do the cognitive work.

```ruby
# Public router process
Legion::Gaia.boot(mode: :router)

# Agent process with router.worker_id configured
Legion::Gaia.boot
```

Router allowlists are enforced both for live registrations and DB-backed worker resolution. If `allowed_worker_ids` is empty, any active worker may be routed; otherwise only listed workers are eligible.

```text
Bot Framework -> GAIA router -> Legion transport -> GAIA agent -> Legion transport -> GAIA router -> Teams
```

## Shutdown Semantics

`Legion::Gaia.shutdown` marks the runtime as quiescing before tearing down components:

1. New heartbeats are blocked.
2. Active heartbeat work is allowed to drain.
3. Phase handlers return `{ status: :skipped, reason: :gaia_shutting_down }` once shutdown starts.
4. Trackers and channel/router bridges are flushed or stopped.
5. Runtime references are cleared.

`shutdown.heartbeat_wait_timeout` bounds how long shutdown waits for in-flight heartbeat work before logging a warning and continuing. `shutdown.heartbeat_wait_log_interval` controls wait-progress logs.

This prevents routine shutdown from producing late writes to closed data/logging resources while still avoiding an indefinite process hang if a heartbeat blocks inside extension work.

## Operational Notes

- `/api/gaia/status` is the lightweight liveness/status surface used by Interlink.
- `/api/gaia/ticks` is the phase-observability stream; every event should have a non-null `duration_ms` and `status`.
- Teams webhook auth is enforced only when `channels.teams.app_id` is configured, which preserves local/dev usage while protecting configured bots.
- Built gem artifacts are not tracked in this repo. Build artifacts belong in release output, not source control.

## Development

```bash
bundle install
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
bundle exec rubocop -A
```

Do not commit `Gemfile.lock` or built `*.gem` artifacts for this gem repo.

## License

Apache-2.0
