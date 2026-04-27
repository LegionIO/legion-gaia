# Legion::Gaia

GAIA is the cognitive coordination layer for LegionIO. It owns the heartbeat loop, phase wiring, sensory buffer, channel adapters, notification gate, and router bridge that let agentic extensions behave like one coherent runtime.

**Version:** 0.9.50

## What GAIA Does

- Boots the cognitive runtime and discovers available agentic extensions.
- Drains inbound channel signals into a bounded sensory buffer.
- Runs the active tick and dream-cycle phase pipeline through `lex-tick`.
- Normalizes phase results for status, timing, logging, and API observability.
- Routes responses through CLI, Microsoft Teams, Slack, or a central router.
- Applies schedule, presence, and behavioral notification gates before delivery.
- Tracks sessions, partner observations, tick history, and lightweight status for Interlink.

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

## Installation

```ruby
gem 'legion-gaia'
```

`legion-gaia` depends on the core LegionIO libraries plus the agentic extension set used by the cognitive pipeline, including `lex-tick`, `legion-apollo`, and the consolidated `lex-agentic-*` gems.

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
```

## Cognitive Phases

GAIA wires two phase groups.

**Active tick:** sensory processing, emotional evaluation, memory retrieval, knowledge retrieval, identity entropy check, working memory integration, procedural check, prediction engine, mesh interface, social cognition, theory of mind, gut instinct, action selection, memory consolidation, homeostasis regulation, and post-tick reflection.

**Dream cycle:** memory audit, association walk, contradiction resolution, agenda formation, curiosity execution, consolidation commit, knowledge promotion, dream reflection, partner reflection, dream narration, dream cycle, creativity tick, lucid dream, epistemic vigilance, predictive processing, free energy, metacognition, default mode network, prospective memory, inner speech, and global workspace.

Phase handlers may skip expensive work when idle. Skipped phases still produce status and timing metadata so the tick stream remains complete.

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

Accepts Microsoft Teams Bot Framework activities. When a Teams `app_id` is configured, requests must include a bearer token. GAIA validates the JWT claims and verifies the signature against Bot Framework signing keys before translating and ingesting the activity.

### `POST /api/gaia/ingest`

Pushes a normalized content payload into the sensory buffer without going through a channel adapter.

## Channel Adapters

| Adapter | Purpose | Notes |
| --- | --- | --- |
| CLI | Local text interaction | Built in and enabled by default. |
| Teams | Bot Framework activity ingestion and proactive delivery | Validates bearer tokens when `app_id` is set. |
| Slack | Slack-style rich text and threaded delivery | Uses the shared channel abstraction. |

Adapters translate format only. Cognitive interpretation happens downstream in the tick pipeline.

## Notification Gate

The notification gate evaluates outbound frames before delivery:

1. `ScheduleEvaluator` checks configured quiet-hour windows.
2. `PresenceEvaluator` maps Teams presence to minimum delivery priority.
3. `BehavioralEvaluator` scores arousal and idle signals.

Urgent or critical frames can bypass quiet-hour delays through `priority_override`. Delayed frames are stored in a bounded queue and re-evaluated each heartbeat.

## Router Mode

GAIA supports hub-and-spoke deployments where a public router relays traffic to private agents over Legion transport.

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

`Legion::Gaia.shutdown` marks the runtime as quiescing before tearing down components. New heartbeats are blocked, active heartbeat work is allowed to finish, and phase handlers skip once shutdown begins. This prevents late shutdown work from writing to closed data/logging resources.

## Development

```bash
bundle install
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
bundle exec rubocop -A
```

Do not commit `Gemfile.lock` or built `*.gem` artifacts for this gem repo.

## License

Apache-2.0
