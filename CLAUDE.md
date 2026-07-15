# legion-gaia

Cognitive coordination layer for LegionIO — a continuously ticking agent runtime. Drains channel
input into a sensory buffer, runs it through a weighted pipeline of agentic cognitive phases via
`lex-tick`, and routes responses back out through schedule/presence/behavioral notification gates.
Provides channel abstraction for multi-interface communication (CLI, Microsoft Teams, Slack).

**GitHub**: https://github.com/LegionIO/legion-gaia

## Build & Test

```bash
bundle install
bundle exec rspec    # 0 failures required before commit
bundle exec rubocop  # 0 offenses required
```

## Where Things Live (most-touched)

| Path | Purpose |
|------|---------|
| `lib/legion/gaia.rb` | Facade: `boot`, `ingest`, `heartbeat`, `respond`, `status`, `shutdown`; heartbeat quiescence, partner-absence and proactive logic |
| `lib/legion/gaia/phase_wiring.rb` | `PHASE_MAP` (37 phases: 16 active + 21 dream), `PHASE_ARGS` lambdas, runner resolution, phase-result annotation |
| `lib/legion/gaia/registry.rb` | Extension discovery, runner wiring, phase-handler management (singleton via `Registry.instance`) |
| `lib/legion/gaia/runner_host.rb` | Extends a runner module onto an instance so modules get persistent `@ivar` state |
| `lib/legion/gaia/sensory_buffer.rb` | Thread-safe bounded signal queue (`MAX_BUFFER_SIZE`) |
| `lib/legion/gaia/actors/heartbeat.rb` | Periodic actor: drain buffer → tick |
| `lib/legion/gaia/input_frame.rb` / `output_frame.rb` | `Data.define` immutable channel frames |
| `lib/legion/gaia/channel_adapter.rb` | Base class: `translate_inbound` / `translate_outbound` / `deliver`; `adapter_classes` registry |
| `lib/legion/gaia/channel_registry.rb` | Active adapters; thread-safe register/unregister/deliver |
| `lib/legion/gaia/channel_aware_renderer.rb` | Adapts content complexity to channel limits + transition suggestions |
| `lib/legion/gaia/output_router.rb` | Chains renderer → notification gate → registry → adapter |
| `lib/legion/gaia/notification_gate.rb` + `notification_gate/` | Schedule / presence / behavioral evaluators + bounded `DelayQueue` |
| `lib/legion/gaia/session_store.rb` | Session continuity keyed by human identity, TTL-based |
| `lib/legion/gaia/router/` | Hub-and-spoke for multi-worker deployments: `WorkerRouting`, `RouterBridge`, `AgentBridge` |
| `lib/legion/gaia/channels/` | `CliAdapter`, `TeamsAdapter` (+ `teams/` auth/webhook), `SlackAdapter` (+ `slack/` signing) |
| `lib/legion/gaia/routes.rb` | Self-registering Sinatra routes under `/api/gaia/*` and `/api/channels/teams/webhook` |
| `lib/legion/gaia/settings.rb` | `Settings.default` — the config schema |
| `lib/legion/gaia/version.rb` | `VERSION` constant (source of truth for the published gem) |

## Data Flow

```
Channel input -> ChannelAdapter#translate_inbound -> InputFrame -> Gaia.ingest -> SensoryBuffer
                                                                                       |
                                                                              Heartbeat tick (lex-tick)
                                                                                       |
Cognitive output <- OutputFrame <- OutputRouter <- NotificationGate <- ChannelAdapter#deliver
```

## HTTP Routes (`routes.rb`)

`GET /api/gaia/status`, `GET /api/gaia/ticks`, `GET /api/gaia/channels`, `GET /api/gaia/buffer`,
`GET /api/gaia/sessions`, `POST /api/gaia/ingest`, `POST /api/channels/teams/webhook`. Registered via
`Legion::API.register_library_routes('gaia', Legion::Gaia::Routes)` at boot.

## Gotchas / Invariants (these prevent real bugs)

- **`lex-tick` is mandatory** — GAIA is inoperable without the tick orchestrator. The heartbeat
  degrades gracefully if the tick runner is unresolvable (warns once, retries next tick).
- **Phase counts**: `PHASE_MAP` is 37 entries — 16 active-tick, 21 dream-cycle. Phases whose runner
  extension isn't loaded are skipped at wiring time; don't assume every phase is always active.
- **Every phase result is annotated** with `status` (`completed`/`skipped`/`failed`) and `elapsed_ms`
  (monotonic). The `/api/gaia/ticks` stream depends on these always being present.
- **Frames are immutable** — `InputFrame`/`OutputFrame` are `Data.define`, frozen, pattern-matchable.
- **Channel adapters are thin and stateless** — translate format only, no business logic, no state;
  they must be recreatable without loss. Authentication is non-negotiable: every channel validates
  identity before input reaches GAIA (Teams JWT/Bot Framework, Slack HMAC-SHA256).
- **Critical/urgent priority bypasses all notification-gate layers.** Gate order is schedule →
  presence → behavioral.
- **Router mode** (`boot(mode: :router)`) boots channels only — no SensoryBuffer or cognitive
  extensions. Worker allowlists are enforced for live registrations *and* DB-backed resolution.
- **Quiescing shutdown** — once `shutdown` starts, phase handlers return
  `{ status: :skipped, reason: :gaia_shutting_down }`; new heartbeats are blocked and in-flight work
  drains (bounded by `shutdown.heartbeat_wait_timeout`). This prevents late writes to closed services.
- **Transport classes load conditionally** — only required when `legion-transport` is available.
- **Settings merge is deep** — `Legion::Gaia.settings` deep-merges `Legion::Settings[:gaia]` over
  `Settings.default`; mutate nested keys, don't replace the whole hash.

## Legion-Wide Rules

- **`Legion::JSON` only** — `Legion::JSON.load` returns **symbol keys**; `.dump` takes exactly one
  positional arg. Inside the `Legion::` namespace, `::JSON` and `::Process` must be explicit.
- **Never swallow exceptions** — every `rescue` re-raises or calls `handle_exception(e, level:,
  operation:)`. Use `log.*` (via `Legion::Gaia::Logging` / `Legion::Logging::Helper`), never `puts`.
- **No personal/company identifiers in VCS.** Never force-push.
- Ruby 3.4+, single quotes, frozen string literals, line length ≤ 120 (see `.rubocop.yml`).
