# legion-gaia — Agent Notes

`legion-gaia` is the **cognitive coordination layer** of the LegionIO framework: a continuously
ticking agent runtime. It drains channel input (CLI, Microsoft Teams, Slack, HTTP) into a sensory
buffer, runs each heartbeat through a weighted pipeline of agentic cognitive phases via `lex-tick`,
and routes responses back out through schedule/presence/behavioral notification gates. See `CLAUDE.md`
for the file map and invariants; `README.md` for the user-facing tour.

## Fast Start

```bash
bundle install
bundle exec rspec    # 0 failures required before commit
bundle exec rubocop  # 0 offenses required
```

Run **both** in full and fix everything before committing.

## Primary Entry Points

- `lib/legion/gaia.rb` — facade (`boot`, `ingest`, `heartbeat`, `respond`, `status`, `shutdown`)
- `lib/legion/gaia/phase_wiring.rb` — `PHASE_MAP` (37 phases: 16 active + 21 dream) + `PHASE_ARGS`
- `lib/legion/gaia/registry.rb` — extension discovery, runner wiring, phase-handler management
- `lib/legion/gaia/actors/heartbeat.rb` — the periodic drain → tick actor
- `lib/legion/gaia/notification_gate.rb` + `notification_gate/` — schedule / presence / behavioral gating
- `lib/legion/gaia/channels/` — `CliAdapter`, `TeamsAdapter`, `SlackAdapter` (+ auth/webhook/signing)
- `lib/legion/gaia/router/` — hub-and-spoke `RouterBridge` / `AgentBridge` / `WorkerRouting`
- `lib/legion/gaia/routes.rb` — self-registering `/api/gaia/*` Sinatra routes
- `lib/legion/gaia/settings.rb` — `Settings.default`, the config schema

## Guardrails / Gotchas (these prevent real bugs)

- **`lex-tick` is mandatory** — GAIA cannot run a tick without it; the heartbeat degrades gracefully
  (warns once, retries) when the tick runner is unresolvable.
- **37 phases, not all always active** — phases whose runner extension isn't loaded are skipped at
  wiring time. Every phase result must carry `status` (`completed`/`skipped`/`failed`) and
  `elapsed_ms`; the `/api/gaia/ticks` stream depends on it.
- **Channel adapters are thin and stateless** — translate format only, no business logic, no state,
  recreatable without loss. Every channel authenticates identity before input reaches GAIA
  (Teams JWT/Bot Framework, Slack HMAC-SHA256).
- **Notification gate order is schedule → presence → behavioral**; critical/urgent priority bypasses
  all layers. Delayed frames sit in a bounded `DelayQueue` re-evaluated each heartbeat.
- **Router mode** (`boot(mode: :router)`) boots channels only — no SensoryBuffer/cognitive
  extensions. Worker allowlists are enforced for live registration and DB-backed resolution.
- **Shutdown is quiescing** — new heartbeats blocked, in-flight work drained, phase handlers return
  `{ status: :skipped, reason: :gaia_shutting_down }`; never let teardown write into closed services.
- **`Legion::JSON` only** (symbol keys); inside `Legion::`, `::JSON`/`::Process` must be explicit.
  Every `rescue` re-raises or `handle_exception`s; use `log.*`, never `puts`.
- **No personal/company identifiers in VCS**; never force-push.
- Settings merge is **deep** (`Legion::Settings[:gaia]` over `Settings.default`) — mutate nested keys.

## Validation

Run targeted specs for the area you touched (`spec/legion/gaia/...`), then full `rspec` + `rubocop`
before handoff. The suite runs in-process without external infrastructure.
