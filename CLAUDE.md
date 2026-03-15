# legion-gaia

**Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## What is this?

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
lib/legion/gaia/channel_aware_renderer.rb # Adapts output complexity to channel capabilities
lib/legion/gaia/output_router.rb        # Routes OutputFrames through renderer to correct adapter
lib/legion/gaia/session_store.rb        # Session continuity tracking, keyed by human identity
lib/legion/gaia/channels/cli_adapter.rb # First concrete adapter — wraps CLI input/output
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

### Data Flow
```
Human Input -> ChannelAdapter#translate_inbound -> InputFrame -> Gaia.ingest -> SensoryBuffer
                                                                                    |
                                                                              Heartbeat tick
                                                                                    |
Cognitive Output -> OutputFrame -> OutputRouter -> ChannelAwareRenderer -> ChannelAdapter#deliver
```

## Dependencies

- `legion-logging` (optional, guarded by `const_defined?`)
- `legion-json` (optional)
- `lex-tick` (runtime, for tick orchestration — not a gem dependency)
- All agentic LEXs are optional runtime dependencies discovered via `Legion::Extensions`

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

## Future (Phase 3-5)

- Teams adapter (Bot Framework JWT validation, adaptive cards, proactive messaging)
- Central router mode (hub-and-spoke via RabbitMQ, stateless router behind load balancer)
- Slack adapter (Socket Mode)
- Cross-channel continuity testing and channel transition suggestions
