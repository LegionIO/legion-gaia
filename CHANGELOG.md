# Changelog

## [0.9.54] - 2026-05-09

### Removed
- Unnecessary `defined?(Legion::Logging)` guards from route handlers — legion-logging is a hard gemspec dependency and always available

## [0.9.53] - 2026-05-08

### Fixed
- Count array-backed Volition intentions when logging cognitive markers so normal action-selection results do not raise `NoMethodError`.
- Skip live Apollo-backed partner reflection for idle `action_selection` argument building when there are no signals or partner observations, preventing zero-signal ticks from embedding relationship lookup queries.
- Stop idle partner-absence checks from polling live Apollo-backed attachment reflection after sustained no-observation heartbeats.

## [0.9.52] - 2026-05-07

### Fixed
- Close the 2026-05-06 GAIA gap-analysis findings across advisory generation, Bot Framework JWT issuer validation, router outbound delivery, offline queuing, proactive partner channels, notification gating, Teams delivery, and shared-state synchronization.
- Normalize advisory routing hints, support string-keyed tool predictions, and return a stable empty advisory hash when advisory generation fails.
- Replace high-severity `log.unknown` message tracing with debug logging to avoid production PII log flooding.
- Harden PR review follow-up behavior for outbound queue acknowledgements, delayed notification TTL preservation, atomic bond channel metadata updates, and adapter delivery-signature caching.

## [0.9.51] - 2026-04-27

### Fixed
- Qualify GAIA phase timing with top-level `::Process` so phase handlers do not fail when `Legion::Process` exists.

## [0.9.50] - 2026-04-27

### Added
- Expose `notification_gate` state in `Legion::Gaia.status` so Interlink can render schedule, presence, and behavioral gate values.
- Add phase-level `elapsed_ms` and stable status annotations (`completed`, `skipped`, `failed`) to GAIA phase handlers, with UI-safe defaults in tick history.
- Add configurable shutdown heartbeat wait timeout and progress logging.

### Fixed
- Require Teams webhook requests to pass through `WebhookHandler` authentication from the API route and reject missing authorization headers when a Teams app ID is configured.
- Verify Bot Framework JWT signatures against the published signing keys instead of accepting unsigned or forged claim payloads.
- Enforce router worker allowlists on DB-backed worker resolution.
- Return status-shaped skipped phase results during shutdown and reuse quiescing phase wrappers across heartbeats.

### Removed
- Remove the tracked `legion-gaia-0.9.10.gem` build artifact from the repository.

## [0.9.49] - 2026-04-27

### Fixed
- Quiesce GAIA heartbeat execution during shutdown so new heartbeats cannot start once shutdown begins, shutdown waits for active heartbeat work to finish, and phase handlers are skipped after shutdown starts.

## [0.9.48] - 2026-04-23

### Fixed
- Cache `partner_absence_exceeds_pattern?` result with 60s TTL to stop Apollo::Local query loop — `reflect_on_bonds` was querying SQLite FTS twice per heartbeat tick (1/sec) with zero results, causing sustained high CPU load

### Added
- Wire 12 new cognitive phases into PHASE_MAP and PHASE_ARGS: `curiosity_execution`, `dream_cycle`, `creativity_tick`, `lucid_dream`, `epistemic_vigilance`, `predictive_processing`, `free_energy`, `metacognition`, `default_mode_network`, `prospective_memory`, `inner_speech`, `global_workspace`
- Idle-skip guards on `social_cognition` and `theory_of_mind` — skip when no signals and no partner observations
- `POST /api/gaia/ingest` REST endpoint for pushing content into the GAIA sensory buffer

## [0.9.47] - 2026-04-07

### Added
- `BondRegistry.register` gains optional `channel_identity:` kwarg to store channel-native user IDs (Slack `U*`, Teams user ID) separate from principal UUID (§9.6)
- `BondRegistry.channel_identity(identity)` method returns the channel-native ID for delivery, falling back to the stored `identity` when no explicit `channel_identity` was registered
- `ProactiveDispatcher#resolve_partner_id` now routes via `BondRegistry.channel_identity` so proactive delivery sends to channel-native IDs rather than principal UUIDs; prevents channel API failures when the bond was registered with a UUID principal

## [0.9.46] - 2026-04-06

### Changed
- BondRegistry: rename `role:` kwarg to `bond:` with backward-compat alias (`role:` accepted, `#role` delegates to `#bond`)
- BondRegistry: replace plain Hash with `Concurrent::Hash` for thread safety; remove lazy `@bonds ||= {}` init guards
- BondRegistry: stored hash entries now carry both `:bond` and `:role` keys during migration window
- BondRegistry: `hydrate_from_apollo` uses `bond:` kwarg internally; call sites updated to use `.bond` method
- `extract_identity` in `gaia.rb` and `router_bridge.rb`: prefer `principal_id` before `aad_object_id` (dual-read §9.3)
- `observe_interlocutor`: calls `BondRegistry.bond` instead of `BondRegistry.role`
- `ProactiveDispatcher`: reads `b[:bond]` instead of `b[:role]` when scanning all_bonds for partner
- `AuditObserver`: dual-read identity extraction — prefers `:identity`, falls back to `:id` (§9.4)
- `SessionStore`: UUID detection via `/\A[0-9a-f]{8}-/i`, string identities normalized to lowercase; `find_or_create` gains `canonical_name:` kwarg for session migration; `@canonical_to_uuid` reverse index added; `remove_unlocked` cleans up all index entries for removed session
- Add `concurrent-ruby >= 1.2` to gemspec dependencies

## [0.9.45] - 2026-04-06

### Fixed
- build real cognitive_state from prior phase results instead of passing empty hash to action_selection
- add cross-tick reflection storage for corrective drive synthesis
- add 8 cognitive state extraction methods to PhaseWiring

## [0.9.44] - 2026-04-02

### Fixed
- Route Teams webhook traffic through `Legion::Gaia.ingest` so webhook-delivered frames use normal signal normalization, session tracking, and interlocutor observation instead of pushing raw frames into the sensory buffer

## [0.9.43] - 2026-04-02

### Fixed
- Preserve undelivered proactive intents when pending dispatch stops mid-drain, prevent failed sends from consuming proactive quota, and fail partner-directed dispatches when no partner channel can be resolved

## [0.9.42] - 2026-04-02

### Fixed
- Keep trackers dirty when Apollo persistence returns a failed upsert response, and avoid advancing the flush timestamp for unsuccessful tracker flushes
- Refresh repo docs to match the current GAIA version and the 25-phase wiring layout

## [0.9.41] - 2026-04-02

### Fixed
- Normalize `RouterBridge#route_outbound` delivery results so adapter-reported error hashes remain undelivered instead of being wrapped as successful outbound delivery

## [0.9.40] - 2026-04-02

### Fixed
- Preserve actual proactive delivery outcomes: `send_message`, `send_to_user`, and `start_conversation` now return failure when adapter or registry delivery reports failure instead of always reporting success
- Include explicit per-channel `:no_adapter` failures in `send_notification` fanout results instead of silently skipping requested channels
- Propagate adapter delivery errors through `ChannelRegistry#deliver` so upstream callers can report real delivery outcomes

## [0.9.39] - 2026-04-02

### Added
- Partner-absence signal queuing: queues an ambient `InputFrame` when `partner_absence_misses` exceeds `ABSENCE_SIGNAL_THRESHOLD` (5), with a 30-minute cooldown (`ABSENCE_SIGNAL_COOLDOWN`) and salience 0.75 to prevent signal flood

### Changed
- Switch non-API GAIA library logging to `Legion::Logging::Helper`, replacing direct `Legion::Logging.*` calls and legacy `log_*` wrappers with helper-backed `log`
- Expand `info`, `debug`, and `error` coverage across GAIA runtime booting, routing, proactive delivery, trackers, adapters, and workflow transitions
- `PhaseWiring` `memory_retrieval` and `prediction_engine` now return `{ skip: true, reason: :idle_no_signals }` when the signals array is empty, skipping expensive phase execution on idle ticks
- `PhaseWiring` `knowledge_retrieval` now reads `signal[:value]` before falling back to `signal[:content]` for the query text
- `PhaseWiring` result normalization: `partner_observations` extracted via `partner_observations_from(ctx)` helper instead of direct `ctx.dig` to normalize observation shape

### Fixed
- Route rescued GAIA library exceptions through `handle_exception` so failures are captured consistently with operation context
- Update GAIA logging specs to support helper-backed tagged logging and keep the full suite green after the logging uplift

## [0.9.38] - 2026-04-01

### Fixed
- Add `require 'time'` in `TickHistory` to ensure `Time#iso8601` is always available
- Deep-dup entries in `TickHistory#recent` with `.map(&:dup)` to prevent callers from mutating ring buffer internals
- Add `gaia_available?` guard to `/api/gaia/ticks` route (returns 503 when GAIA not started)
- Use `TickHistory::MAX_ENTRIES` instead of hardcoded `200` for ticks route limit cap
- Track `@started_at` in `boot_router` for accurate uptime in router mode

## [0.9.37] - 2026-04-01

### Added
- `TickHistory` ring buffer (max 200 entries): records per-phase events (timestamp, phase name, duration_ms, status) from each heartbeat tick result
- `GET /api/gaia/ticks` route: returns recent tick phase events with configurable `limit` param (1–200, default 50)
- Enhanced `/api/gaia/status` response: `tick_count`, `tick_mode`, nested `sensory_buffer` (depth + max_capacity), nested `sessions_detail` (active_count + ttl), `uptime_seconds`
- `tick_history` and `tick_count` accessors on `Legion::Gaia`
- `@started_at` tracked on boot for uptime calculation

### Changed
- `notifications.enabled` default changed from `false` to `true` in `Settings.default_notifications`

## [0.9.36] - 2026-03-31

### Fixed
- Wire `TrackerPersistence.hydrate_all` on boot when Apollo Local is available (restores calibration data after reboot)
- Wire `BondRegistry.hydrate_from_apollo` on boot when Apollo Local is available (restores partner bonds after reboot)
- Implement `SlackAdapter#deliver_via_api`: real HTTP POST to `chat.postMessage` using `net/http` (replaces `:not_implemented` stub)
- Fix `TeamsAdapter#deliver` signature mismatch: accept `default_conversation_id` from settings as fallback when no `conversation_id` is passed
- Expand `ScheduleEvaluator#tz_offset` from 6 hardcoded zones to 29 IANA zones with DST-aware offsets; use `TZInfo` when available
- Implement `ProactiveDispatcher#resolve_partner_channel`: read `preferred_channel` or `last_channel` from `BondRegistry` partner bond

## [0.9.34] - 2026-03-31

### Added
- IntentClassifier: 7 interaction intent types (casual, question, directive, seeking_advice, greeting, urgent, direct_engage)
- Intent classification wired into ChannelAdapter `build_intent_metadata` (replaces boolean `direct_address`)
- TeamsAdapter `translate_inbound` uses `**build_intent_metadata` for richer inbound metadata
- ProactiveDispatcher: frequency-limited proactive message delivery (3/day, 2hr interval, 24hr ignore cooldown), pending buffer (max 5), content generation via LLM
- PresenceEvaluator: offline detection (`partner_offline?`, `offline_duration`, `transitioned_online?`, `status_changed_at` tracking)
- Dream-to-proactive bridge: `process_dream_proactive` queues intents from dream cycle results; `try_dispatch_pending` drains and delivers via gated dispatcher
- PHASE_ARGS: `action_selection` now passes `bond_state` from `partner_reflection` prior results

## [0.9.33] - 2026-03-31

### Added
- Wire `partner_reflection` dream phase in PHASE_MAP + PHASE_ARGS (Phase C bond reflection)

## [0.9.32] - 2026-03-31

### Added
- Partner absence emotional response: heartbeat tracks consecutive ticks without partner observations when prediction_engine phase is wired
- `check_partner_absence` injects absence valence into `@last_valences` with logarithmic importance scaling (0.4 base, capped at 0.7)
- Absence valence uses lex-agentic-affect `Helpers::Valence.absence_importance` when available, inline fallback otherwise
- `@last_valences` cleared on shutdown to prevent state leakage

## [0.9.31] - 2026-03-31

### Added
- NotificationGate signal feeds: heartbeat feeds arousal from emotional_evaluation valence and Teams presence status into the gate
- `process_delayed` call in heartbeat — delayed notification frames are now retried each tick
- `last_presence_status` and `update_presence_status` on TeamsAdapter for presence signal tracking
- `@notification_gate` stored as instance variable for direct heartbeat access

## [0.9.30] - 2026-03-31

### Added
- `BondRegistry` — partner identity management, hydrates from Apollo Local seed data
- `TrackerPersistence` — flush/hydrate lifecycle for Apollo Local, 5-min interval dirty flush, flush-all on shutdown
- `observe_interlocutor` in `Gaia.ingest` — extracts identity from auth_context, builds observation hash for tick phases
- `human_observations` kwarg in PHASE_ARGS for social_cognition, theory_of_mind, emotional_evaluation
- `direct_address` detection in channel adapters via `/\bgaia\b/i` pattern
- Episodic memory traces for partner interactions (guarded by lex-agentic-memory)
- `partner_observations` attr_reader on Gaia singleton, drained into tick state each heartbeat

## [0.9.29] - 2026-03-28

### Fixed
- Rate-limit the `[gaia] lex-tick not available` warning in `heartbeat` so it logs only once per unavailability window instead of every second; resets when tick becomes available again or on boot/shutdown

## [0.9.28] - 2026-03-28

### Added
- Generic state machine DSL for workflow orchestration (`lib/legion/gaia/workflow.rb` and `lib/legion/gaia/workflow/`)
- `Legion::Gaia::Workflow` module — include into any class to get the `workflow` DSL class method and `create_workflow` factory
- `Legion::Gaia::Workflow.define` — standalone factory for building a Definition without a host class
- `Legion::Gaia::Workflow::Definition` — DSL class: `state`, `transition` (with `guard:`/`guard_name:`), `checkpoint`, `on_enter`, `on_exit`
- `Legion::Gaia::Workflow::Instance` — runtime instance with `transition!`, `transition`, `in_state?`, `can_transition_to?`, `available_transitions`, `status`, and transition history; mutex-protected for thread safety
- `Legion::Gaia::Workflow::Checkpoint` — `Data.define` value object, evaluated at exit time with configurable condition lambda
- Error hierarchy: `Workflow::Error`, `InvalidTransition`, `GuardRejected`, `CheckpointBlocked`, `UnknownState`, `NotInitialized`
- 106 specs covering DSL, transitions, guards, checkpoints, callbacks, thread safety, and end-to-end scenarios

## [0.9.27] - 2026-03-28

### Added
- `Legion::Gaia::Routes` self-registering Sinatra route module (`lib/legion/gaia/routes.rb`): extracts all `/api/gaia/*` route handlers from LegionIO. Self-registers with `Legion::API.register_library_routes('gaia', Routes)` during boot. Includes fallback helpers for standalone mounting.

## [0.9.26] - 2026-03-25

### Added
- `core_library_runner` private method in `PhaseWiring` — checks `Legion::` namespace directly before falling through to `Legion::Extensions`
- `resolve_runner_class` now resolves core library runners (e.g., `Legion::Apollo::Runners::Request`) first, enabling GAIA phases to wire against the `legion-apollo` core gem without requiring `lex-apollo` to be co-located
- Added `legion-apollo >= 0.2.1` to gemspec dependencies alongside existing `lex-apollo` dep

## [0.9.25] - 2026-03-25

### Fixed
- `PhaseWiring#resolve_runner_class` now performs a deep search through `Extensions::Agentic::Domain::ext_sym::Runners::runner_sym` when the extension constant is not found at the flat or one-level-deep Agentic paths
- Added `deep_agentic_runner` helper that walks each domain gem under `Extensions::Agentic` to find the runner nested two levels deep (e.g., `Agentic::Affect::Emotion::Runners::Valence`)
- All 9 previously missing phases now wire correctly: `emotional_evaluation`, `identity_entropy_check`, `prediction_engine`, `gut_instinct`, `action_selection`, `contradiction_resolution`, `agenda_formation`, `dream_narration`, and the Curiosity step in `working_memory_integration`
- Phase wiring coverage increases from 15/24 to 24/24

## [0.9.24] - 2026-03-25

### Changed
- GAIA phase wiring: `knowledge_retrieval` now targets `Apollo::Request#retrieve` instead of `Apollo::Knowledge#retrieve_relevant`, enabling knowledge queries from agent nodes without direct DB access

## [0.9.23] - 2026-03-24

### Added
- `Singleton` mixin on `Gaia::Actors::Heartbeat` — only leader node runs the cognitive tick cycle when `cluster.singleton_enabled` is true (default: off, every node ticks as before)

## [0.9.22] - 2026-03-24

### Changed
- Channel adapter auto-discovery: `boot_channels` now iterates `ChannelAdapter.adapter_classes` instead of hard-coding Teams/Slack/CLI
- Each adapter implements `self.from_settings(settings)` factory method for self-registration
- `ChannelAdapter.inherited` hook auto-registers subclasses — new adapters need zero changes to `gaia.rb`
- Removed `register_slack_adapter` private method (absorbed into auto-discovery loop)

## [0.9.21] - 2026-03-24

### Added
- Wire `social_cognition` phase (lex-agentic-social Social runner, `update_social`) after `mesh_interface`
- Wire `theory_of_mind` phase (lex-agentic-social TheoryOfMind runner, `update_theory_of_mind`) after `social_cognition`
- Wire `homeostasis_regulation` phase (lex-agentic-homeostasis Homeostasis runner, `regulate`) after `memory_consolidation`
- PHASE_MAP grows from 21 to 24 entries (16 active + 8 dream)

## [0.9.20] - 2026-03-24

### Changed
- Phase wiring knowledge retrieval, memory retrieval, and memory audit limits now read from `Legion::Settings[:gaia][:knowledge]` instead of hardcoded values
- Configurable keys: `retrieval_limit`, `retrieval_min_confidence`, `memory_retrieval_limit`, `memory_audit_limit`, `memory_skip_threshold`

## [0.9.19] - 2026-03-24

### Added
- Declare 5 PHASE_MAP operational dependencies: lex-apollo, lex-coldstart, lex-detect, lex-mesh, lex-synapse
- All 19 PHASE_MAP phases now resolve out of the box on `gem install legion-gaia`

## [0.9.18] - 2026-03-24

### Added
- Declare `legion-settings` as explicit dependency (used at runtime for config)
- Declare `openssl` as explicit dependency (required for Teams/Slack auth, Ruby 3.4+ bundled gem)

## [0.9.17] - 2026-03-23

### Fixed
- Pass `false` inherit parameter to `Legion.const_defined?` in `settings` method to prevent incorrect constant resolution through `Object`

## [0.9.16] - 2026-03-23

### Changed
- Bump lex-agentic-self dependency to >= 0.1.4

## [0.9.14] - 2026-03-23

### Fixed
- Convert Registry to singleton pattern to satisfy constant safety lint

## [0.9.13] - 2026-03-23

### Added
- GAIA advisory layer for pre-flight LLM request enrichment
- Audit observer for learning from LLM interaction patterns

## [0.9.12] - 2026-03-23

### Changed
- `knowledge_promotion` PHASE_ARGS now synthesizes actual dream cycle insights from prior phase results instead of sending a static placeholder string to Apollo
- Extracted `build_promotion_content` with per-phase helpers: `extract_association`, `extract_conflicts`, `extract_consolidation`, `extract_reflection`, `extract_agenda`
- Returns `{ skip: true }` when no dream phases produced meaningful results

## [0.9.11] - 2026-03-23

### Added
- `knowledge_promotion` phase wiring: maps to `Apollo::Knowledge.handle_ingest` for dream cycle Apollo integration

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
