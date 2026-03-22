# Changelog

## [0.9.10] - 2026-03-22

### Changed
- Updated gemspec dependency version constraints: `legion-json >= 1.2.0` and `legion-logging >= 1.2.8`

## [0.9.9] - 2026-03-22

### Changed
- Added `Legion::Logging` calls to all silent rescue blocks (16 total) so no exception is swallowed without a trace
- `channels/slack_adapter.rb`: `.warn` on open_dm failure
- `channels/teams/bot_framework_auth.rb`: `.debug` on JWT segment decode failure (expected for malformed tokens)
- `channels/teams/webhook_handler.rb`: `.debug` on activity parse failure
- `channels/teams_adapter.rb`: `.warn` on create_proactive_conversation failure
- `offline_handler.rb`: `.warn` on notify_sender failure, `.debug` on offline_threshold settings failure
- `proactive.rb`: `.warn` on send_message, send_to_user, send_notification, and start_conversation failures
- `router/agent_bridge.rb`: `.warn` on reconstruct_input_frame and decode_payload failures
- `router/router_bridge.rb`: `.warn` on reconstruct_output_frame failure
- `teams_auth.rb`: `.warn` on check_teams_auth and teams_authenticated? failures

## [0.9.8] - 2026-03-21

### Fixed
- `PhaseWiring#resolve_runner_class` now searches `Legion::Extensions::Agentic::` sub-namespace when the extension constant is not found directly under `Legion::Extensions`
- Added sub-domain runner lookup (one level deep) so agentic extensions that nest runners under `Extension::SubDomain::Runners::Runner` are resolved correctly
- All `const_defined?` and `const_get` calls now pass `inherit: false` to prevent incorrect constant resolution through `Object`

## [0.9.7] - 2026-03-20

### Fixed
- Use `::Data.define` instead of `Data.define` in `SessionStore`, `ConversationStore::Reference`, and `ConversationStore::UserProfile` to avoid constant resolution collision with `Legion::Data`

## [0.9.6] - 2026-03-19

### Added
- `Legion::Gaia::Proactive.send_to_user` — delivers a proactive message to a user across one channel or all known channels, using `deliver_proactive` when the adapter supports it
- `Legion::Gaia::Proactive.send_notification` — routes a notification through the OutputRouter (respects NotificationGate quiet hours, presence, and behavioral scoring); supports :ambient/:normal/:urgent/:critical priority
- `Legion::Gaia::Proactive.start_conversation` — initiates an agent-started conversation with a user who has not messaged first; delegates to `deliver_proactive` on adapters that support it
- `TeamsAdapter#deliver_proactive` — resolves an existing conversation reference by user (via tenant match) or creates a new one via Bot Framework `POST /v3/conversations`; delivers the OutputFrame proactively
- `TeamsAdapter#create_proactive_conversation` — creates a new Bot Framework conversation and stores the resulting reference in ConversationStore
- `ConversationStore::UserProfile` — new `Data.define` value object storing `user_id`, `service_url`, `tenant_id` at the user level
- `ConversationStore#store_user_profile` / `#lookup_user_profile` — store and retrieve user-level service URL and tenant from any prior activity
- `ConversationStore#conversations_for_user` — returns all conversation references whose tenant matches the user's stored profile (enables cross-conversation proactive targeting)
- `ConversationStore#store_from_activity` now also populates the user profile from the `from.id` field
- `SlackAdapter#open_dm` — opens a Slack DM channel via `conversations.open` API (requires `im:write` scope and `bot_token`)
- `SlackAdapter#deliver_proactive` — opens a DM for the target user then delivers the OutputFrame via bot token API
- 22 new specs (366 total) covering all new proactive methods across Proactive module, TeamsAdapter, SlackAdapter, and ConversationStore

## [0.9.5] - 2026-03-20

### Fixed
- Use `::Data.define` instead of `Data.define` in `InputFrame` and `OutputFrame` to avoid constant resolution collision with `Legion::Data` within the `Legion` namespace

## [0.9.4] - 2026-03-20

### Changed
- Version bump for deployment (0.9.3 was released before observer and module extraction changes landed)

## [0.9.3] - 2026-03-20

### Added
- Register `Detect::TaskObserver#observe` in `post_tick_reflection` phase for incremental task anomaly detection on every tick cycle
- `post_tick_reflection` PHASE_ARGS now includes `since: ctx.dig(:state, :last_observer_tick)` for incremental DB observation scans

### Changed
- Extract logging and teams auth methods into `Legion::Gaia::Logging` and `Legion::Gaia::TeamsAuth` modules to fix rubocop ModuleLength/ClassLength offenses

## [0.9.2] - 2026-03-18

### Changed
- Replace 242 individual lex-* agentic extension dependencies with 15 consolidated deps
- Add `lex-tick` (tick orchestrator — GAIA is inoperable without it)
- Add `lex-privatecore` (privacy enforcement for the cognitive stack)
- Add 13 `lex-agentic-*` consolidated domain gems (affect, attention, defense, executive, homeostasis, imagination, inference, integration, language, learning, memory, self, social)
- Runtime-discovered extensions (lex-apollo, lex-coldstart, lex-mesh, lex-mind-growth) remain optional

## [0.9.1] - 2026-03-18

### Fixed
- Remove local path references from Gemfile (legion-json, legion-logging, all commented agentic extensions)

## [0.9.0] - 2026-03-17

### Changed
- **BREAKING**: GAIA inbound queues migrated from `gaia.inbound.<worker_id>` to `agent.<worker_id>` on the agent exchange
- Inbound queue class now inherits from `Legion::Transport::Queues::Agent`
- InputFrameMessage publishes to agent exchange instead of gaia exchange
- Gaia exchange retained for outbound fan-in only (OutputFrameMessage unchanged)

### Added
- Depends on legion-transport >= 1.2.2 for agent exchange/queue support

## [0.8.1] - 2026-03-17

### Added
- Synapse cognitive routing hooks at tick phase 5 (working_memory_integration) and phase 12 (post_tick_reflection)
- Multi-handler support in `PhaseWiring::PHASE_MAP` — phases can now have arrays of handlers
- `PhaseWiring.mappings_for` helper normalizes single-hash and array-valued phase entries
- 9 new specs (319 total)

## [0.8.0] - 2026-03-17

### Added
- `Legion::Gaia::Proactive`: agent-initiated messaging to any channel via channel registry
- `Legion::Gaia::OfflineHandler`: message queuing and sender notification for offline agents
- Presence tracking with configurable offline threshold
- `drain_pending` and `pending_count` for offline message management
- 14 new specs (310 total)

## [0.7.0] - 2026-03-15

### Changed
- Added 242 agentic lex-* gems as runtime dependencies (full cognitive stack meta-package)
- Installing legion-gaia now pulls in all cognitive extensions

## [0.6.0] - 2026-03-15

### Added
- `Legion::Gaia::NotificationGate` three-layer notification gate between OutputRouter and channel delivery
- `Legion::Gaia::NotificationGate::ScheduleEvaluator` config-driven quiet hours with time window, day-of-week, and timezone support
- `Legion::Gaia::NotificationGate::PresenceEvaluator` Teams presence status gating (Available/Busy/Away/DoNotDisturb/Offline mapped to priority thresholds)
- `Legion::Gaia::NotificationGate::BehavioralEvaluator` learned signal scoring using arousal and idle time
- `Legion::Gaia::NotificationGate::DelayQueue` thread-safe delayed message queue with max size eviction and TTL expiration
- Priority override: critical and urgent messages bypass quiet hours
- OutputRouter integration: notification gate evaluates frames before delivery, delayed frames re-evaluated on heartbeat
- Notification settings in `Legion::Gaia::Settings` (enabled, quiet_hours, priority_override, delay_queue_max, max_delay)
- 63 new specs (296 total) with full coverage across all Phase 6 components

## [0.5.0] - 2026-03-15

### Added
- `Legion::Gaia::Channels::SlackAdapter` Slack channel adapter with webhook and signing secret support
- `Legion::Gaia::Channels::Slack::SigningVerifier` HMAC-SHA256 request verification for Slack Events API
- Slack adapter auto-registration when `channels.slack.enabled` is true in settings
- Bot mention stripping for Slack events (`<@UBOT>` tags)
- Thread-aware outbound delivery (preserves `thread_ts` for reply threading)
- Channel transition suggestions in `ChannelAwareRenderer` when content is truncated
- Transition suggestion messages point users to richer channels (e.g., "Full response available on cli")
- 19 new specs (233 total) with full coverage across all Phase 5 components

## [0.4.0] - 2026-03-15

### Added
- `Legion::Gaia::Router` central router module for hub-and-spoke deployment
- `Legion::Gaia::Router::RouterBridge` inbound/outbound message routing between channels and agents via RabbitMQ
- `Legion::Gaia::Router::AgentBridge` agent-side transport: subscribes to inbound queue, publishes OutputFrames
- `Legion::Gaia::Router::WorkerRouting` thread-safe identity-to-worker routing table with allowlist support
- `Legion::Gaia::Router::Transport::Exchanges::Gaia` topic exchange for InputFrame/OutputFrame routing
- `Legion::Gaia::Router::Transport::Queues::Inbound` per-worker inbound queue (router->agent)
- `Legion::Gaia::Router::Transport::Queues::Outbound` shared outbound queue (agent->router)
- `Legion::Gaia::Router::Transport::Messages::InputFrameMessage` publishes InputFrames to RabbitMQ
- `Legion::Gaia::Router::Transport::Messages::OutputFrameMessage` publishes OutputFrames to RabbitMQ
- Dual boot modes: `Legion::Gaia.boot(mode: :router)` for stateless router, default `:agent` for full GAIA
- Router mode skips brain (no SensoryBuffer, Registry, or cognitive extensions)
- Agent bridge auto-starts when `router.mode` and `router.worker_id` configured
- `Legion::Gaia.respond` publishes through agent bridge when available (agent->router->channel)
- 31 new specs (214 total) with full coverage across all Phase 4 components

## [0.3.0] - 2026-03-15

### Added
- `Legion::Gaia::Channels::TeamsAdapter` Teams channel adapter with Bot Framework activity translation
- `Legion::Gaia::Channels::Teams::BotFrameworkAuth` JWT token validation for Bot Framework and Emulator issuers
- `Legion::Gaia::Channels::Teams::ConversationStore` thread-safe conversation reference storage for reply delivery
- `Legion::Gaia::Channels::Teams::WebhookHandler` HTTP webhook handler routing Bot Framework activity types
- Bot @mention stripping from inbound messages
- Mobile/desktop device context detection from Teams clientInfo
- Adaptive card content type support in translate_outbound
- Teams adapter auto-registration when `channels.teams.enabled` is true in settings
- `base64` gem dependency (required for Ruby 3.4+ JWT decoding)
- 54 new specs (183 total) with full coverage across all Phase 3 components

## [0.2.0] - 2026-03-15

### Added
- `Legion::Gaia::InputFrame` immutable value object (Data.define) for channel-agnostic inbound messages
- `Legion::Gaia::OutputFrame` immutable value object (Data.define) for channel-agnostic outbound responses
- `Legion::Gaia::ChannelAdapter` base class defining the adapter contract (translate_inbound/outbound, deliver)
- `Legion::Gaia::ChannelRegistry` thread-safe registry for active channel adapters with deliver routing
- `Legion::Gaia::ChannelAwareRenderer` adapts output complexity to channel capabilities (truncation, switch suggestions)
- `Legion::Gaia::OutputRouter` chains renderer -> registry -> adapter for output delivery
- `Legion::Gaia::SessionStore` session continuity tracking keyed by human identity with TTL expiration
- `Legion::Gaia::Channels::CliAdapter` first concrete adapter for CLI input/output
- `Legion::Gaia.ingest(input_frame)` pushes signals to sensory buffer and manages session continuity
- `Legion::Gaia.respond(content:, channel_id:)` routes output through renderer and adapter
- Channel infrastructure auto-boots during `Legion::Gaia.boot` (CLI adapter registered by default)
- 129 specs with full coverage across all Phase 1 and Phase 2 components

## [0.1.0] - 2026-03-15

### Added
- `Legion::Gaia` entry point with boot/shutdown lifecycle, settings, heartbeat, and status
- `Legion::Gaia::Registry` for subordinate function discovery, capability mapping, and health tracking
- `Legion::Gaia::PhaseWiring` absorbs PHASE_MAP (19 phases: 12 active tick + 7 dream cycle) from lex-cortex
- `Legion::Gaia::RunnerHost` provides persistent instance state for runner modules via extend pattern
- `Legion::Gaia::SensoryBuffer` thread-safe signal buffer (renamed from cortex SignalBuffer)
- `Legion::Gaia::Actors::Heartbeat` drives the cognitive tick cycle at configurable interval (default 1s)
- `Legion::Gaia::Settings` default configuration for channels, router, sessions, and output
- 63 specs with full coverage across all components
