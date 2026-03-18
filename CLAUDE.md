# legion-gaia: Cognitive Coordination Layer for LegionIO

**Repository Level 3 Documentation**
- **Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`
- **GitHub**: https://github.com/LegionIO/legion-gaia
- **Version**: 0.8.0

## Purpose

Cognitive coordination layer for LegionIO. GAIA absorbs and replaces `lex-cortex`, elevating the cognitive wiring from an extension to a core library. It drives the tick cycle, discovers and wires agentic extensions, and provides channel abstraction for multi-interface communication (CLI, Teams, Slack).

## Key Files

```
lib/legion/gaia.rb                      # Entry point: boot, shutdown, heartbeat, ingest, respond, status
lib/legion/gaia/version.rb              # VERSION constant
lib/legion/gaia/settings.rb             # Default config hash (channels, router, session, output)
lib/legion/gaia/registry.rb             # Extension discovery, runner wiring, phase handler management
lib/legion/gaia/phase_wiring.rb         # PHASE_MAP (19 phases), PHASE_ARGS, resolve/build helpers
lib/legion/gaia/runner_host.rb          # Wraps runner modules with isolated instance state via extend
lib/legion/gaia/sensory_buffer.rb       # Thread-safe signal queue (max 1000, normalized)
lib/legion/gaia/actors/heartbeat.rb     # Every-1s actor, drains buffer and drives tick
lib/legion/gaia/input_frame.rb          # Data.define — immutable inbound message from any channel
lib/legion/gaia/output_frame.rb         # Data.define — immutable outbound response to any channel
lib/legion/gaia/channel_adapter.rb      # Base class for channel adapters (translate in/out, deliver)
lib/legion/gaia/channel_registry.rb     # Registry of active channel adapters, thread-safe
lib/legion/gaia/channel_aware_renderer.rb # Adapts output complexity to channel capabilities + transition suggestions
lib/legion/gaia/output_router.rb        # Routes OutputFrames through renderer to correct adapter
lib/legion/gaia/session_store.rb        # Session continuity tracking, keyed by human identity
lib/legion/gaia/channels/cli_adapter.rb # First concrete adapter — wraps CLI input/output
lib/legion/gaia/channels/teams_adapter.rb           # Teams adapter — Bot Framework activities to Frames
lib/legion/gaia/channels/teams/bot_framework_auth.rb # JWT validation for Bot Framework tokens
lib/legion/gaia/channels/teams/conversation_store.rb # Thread-safe conversation reference storage
lib/legion/gaia/channels/teams/webhook_handler.rb    # HTTP webhook handler for Bot Framework activities
lib/legion/gaia/channels/slack_adapter.rb            # Slack adapter — Events API to Frames
lib/legion/gaia/channels/slack/signing_verifier.rb   # HMAC-SHA256 request verification for Slack Events API
lib/legion/gaia/router.rb                            # Router module entry point, conditional transport loading
lib/legion/gaia/router/worker_routing.rb             # Identity-to-worker routing table with allowlist
lib/legion/gaia/router/router_bridge.rb              # Central router: inbound routing + outbound delivery
lib/legion/gaia/router/agent_bridge.rb               # Agent-side: subscribe inbound, publish outbound
lib/legion/gaia/router/transport/exchanges/gaia.rb   # Topic exchange for GAIA frames
lib/legion/gaia/router/transport/queues/inbound.rb   # Per-worker inbound queue (router->agent)
lib/legion/gaia/router/transport/queues/outbound.rb  # Shared outbound queue (agent->router)
lib/legion/gaia/router/transport/messages/input_frame_message.rb  # InputFrame -> RabbitMQ
lib/legion/gaia/router/transport/messages/output_frame_message.rb # OutputFrame -> RabbitMQ
lib/legion/gaia/notification_gate.rb                        # Three-layer gate between OutputRouter and delivery
lib/legion/gaia/notification_gate/schedule_evaluator.rb     # Config-driven quiet hours (day/time/timezone windows)
lib/legion/gaia/notification_gate/presence_evaluator.rb     # Teams presence status -> priority threshold mapping
lib/legion/gaia/notification_gate/behavioral_evaluator.rb   # Learned signal scoring (arousal, idle time)
lib/legion/gaia/notification_gate/delay_queue.rb            # Thread-safe delayed message queue (max size, TTL)
lib/legion/gaia/proactive.rb                                # Proactive message delivery: send_message, broadcast to channels
lib/legion/gaia/offline_handler.rb                          # Offline agent handling: queue messages, notify sender, presence tracking
```

## Architecture

### Phase 1: Cortex Absorption
- `Legion::Gaia.boot` creates SensoryBuffer, Registry, and ChannelRegistry, runs discovery
- `Registry#discover` walks `PHASE_MAP`, resolves runner classes via `Legion::Extensions`, wraps in `RunnerHost`
- `Legion::Gaia.heartbeat` drains buffer, calls `tick_host.execute_tick(signals:, phase_handlers:)`
- Heartbeat actor calls `heartbeat` every 1s (configurable via settings)
- Graceful degradation: if lex-tick not loaded, heartbeat returns `{ error: :no_tick_extension }` and retries next tick

### Phase 2: Channel Abstraction
- `InputFrame` and `OutputFrame` are immutable `Data.define` value objects — the universal message format
- `ChannelAdapter` base class defines the contract: `translate_inbound`, `translate_outbound`, `deliver`
- `ChannelRegistry` manages active adapters, thread-safe register/unregister/deliver
- `ChannelAwareRenderer` pre-adapts content complexity (truncation, channel switch suggestions)
- `OutputRouter` chains renderer -> registry -> adapter for delivery
- `SessionStore` tracks session continuity across channels, keyed by human identity with TTL
- `CliAdapter` is the first concrete adapter — translates raw strings to InputFrames, buffers output
- `Legion::Gaia.ingest(input_frame)` pushes to sensory buffer and creates/touches session
- `Legion::Gaia.respond(content:, channel_id:)` routes output through renderer and adapter

### Phase 3: Teams Channel Adapter
- `TeamsAdapter` translates Bot Framework activities to InputFrames and OutputFrames to Teams messages
- `BotFrameworkAuth` validates JWT tokens from Bot Framework and Emulator issuers (claims, expiry, audience)
- `ConversationStore` holds `service_url` + `conversation_id` references needed for reply delivery (thread-safe)
- `WebhookHandler` routes inbound activities by type: message, conversationUpdate, invoke, other
- Bot @mention stripping ensures clean text reaches the cognitive pipeline
- Mobile/desktop device detection from `channelData.clientInfo.platform`
- Delivery uses `lex-microsoft_teams` Bot runner (`send_text`/`send_card`) when available
- Teams adapter auto-registers during `boot_channels` when `channels.teams.enabled` is true

### Phase 4: Central Router (Hub-and-Spoke)
- Dual boot modes: `Legion::Gaia.boot(mode: :router)` for stateless router, default `:agent` for full GAIA
- Router mode: boots channels only — no SensoryBuffer, Registry, or cognitive extensions
- `RouterBridge` handles inbound routing (identity -> worker_id -> RabbitMQ queue) and outbound delivery
- `AgentBridge` subscribes to per-worker inbound queue, pushes InputFrames into local GAIA SensoryBuffer
- `AgentBridge` publishes OutputFrames to outbound queue when `respond` is called
- `WorkerRouting` maps Entra OID / identity to worker_id with allowlist enforcement
- Transport layer follows standard legion-transport patterns (Exchange, Queue, Message base classes)
- Transport classes only loaded when `legion-transport` is available (conditional require)
- Router never sees cognitive state — only InputFrame/OutputFrame envelopes

### Phase 5: Slack Adapter + Cross-Channel Polish
- `SlackAdapter` translates Slack Events API payloads to InputFrames and OutputFrames to Slack messages
- `SigningVerifier` validates inbound requests via HMAC-SHA256 (signing secret + timestamp + body)
- Bot `<@UBOT>` mention stripping for clean text input
- Thread-aware outbound delivery (preserves `thread_ts` for reply threading)
- Slack adapter auto-registers during `boot_channels` when `channels.slack.enabled` is true
- `ChannelAwareRenderer` adds transition suggestions when content is truncated (e.g., "Full response available on cli")
- Richness hierarchy: voice -> slack -> cli (richer channels suggested when content exceeds limits)

### Phase 6: Notification Gate
- `NotificationGate` sits between OutputRouter and channel delivery, evaluating each frame
- Three evaluation layers in order: schedule (quiet hours) -> presence (Teams status) -> behavioral (learned signals)
- `ScheduleEvaluator` parses config-driven schedule arrays with day/time/timezone windows, handles overnight wraps
- `PresenceEvaluator` maps Teams availability states to minimum priority thresholds (Available->ambient, Busy/Away->urgent, DoNotDisturb/Offline->critical)
- `BehavioralEvaluator` uses arousal (0.0-1.0) and idle_seconds signals to compute notification score
- Priority override: critical/urgent messages bypass all layers
- `DelayQueue` is thread-safe with mutex, max_size eviction, TTL-based expiration, flush
- OutputRouter calls `notification_gate.evaluate(frame)` -> `:deliver` or `:delay`
- Delayed frames re-evaluated each heartbeat tick via `process_delayed` (drain expired, flush when quiet ends)

### Data Flow
```
Human Input -> ChannelAdapter#translate_inbound -> InputFrame -> Gaia.ingest -> SensoryBuffer
                                                                                    |
                                                                              Heartbeat tick
                                                                                    |
Cognitive Output -> OutputFrame -> OutputRouter -> ChannelAwareRenderer -> ChannelAdapter#deliver
```

## Patterns

- `RunnerHost` uses `extend runner_module` on instances to give modules persistent `@ivar` state
- `Registry` tracks `@discovered` boolean to prevent re-discovery when results are empty
- `PhaseWiring::PHASE_ARGS` lambdas build kwargs from a context hash; `association_walk` is the most complex
- Settings fall through: `Legion::Settings[:gaia]` if available, else `Legion::Gaia::Settings.default`
- `InputFrame`/`OutputFrame` use `Data.define` for immutability — frozen by default, pattern-matchable
- Channel adapters are deliberately thin: translate format, not content. No business logic, no state
- `SessionStore` uses identity-indexed lookup with TTL-based expiration and channel history tracking

## Architectural Constraints

1. No channel-specific state — adapters store nothing, destroy and recreate without loss
2. No channel-specific logic — adapters translate format, not content
3. Authentication is non-negotiable — every channel validates identity before input reaches GAIA
4. Private core protections are channel-independent
5. Human controls channel availability — any channel can be disabled at any time

## Dependencies

- `base64` (required, Ruby 3.4+ removed from default gems)
- `legion-logging` (optional, guarded by `const_defined?`)
- `legion-json` (optional)
- `legion-transport` (optional, for router mode — not a gem dependency)
- `lex-tick` (runtime, for tick orchestration — not a gem dependency)
- `lex-microsoft_teams` (runtime, for Teams delivery — not a gem dependency)
- All agentic LEXs are optional runtime dependencies discovered via `Legion::Extensions`

## Future

- Voice adapter
- Proactive notification scheduling (agent-initiated messages at optimal delivery times)

---

**Maintained By**: Matthew Iverson (@Esity)
