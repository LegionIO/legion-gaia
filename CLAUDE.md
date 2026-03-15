# legion-gaia

**Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## What is this?

Cognitive coordination layer for LegionIO. GAIA absorbs and replaces `lex-cortex`, elevating the cognitive wiring from an extension to a core library. It drives the tick cycle, discovers and wires agentic extensions, and will provide channel abstraction for multi-interface communication (CLI, Teams, Slack).

## Key Files

```
lib/legion/gaia.rb              # Entry point: boot, shutdown, heartbeat, status, settings
lib/legion/gaia/version.rb      # VERSION constant
lib/legion/gaia/settings.rb     # Default config hash (channels, router, session, output)
lib/legion/gaia/registry.rb     # Extension discovery, runner wiring, phase handler management
lib/legion/gaia/phase_wiring.rb # PHASE_MAP (19 phases), PHASE_ARGS, resolve/build helpers
lib/legion/gaia/runner_host.rb  # Wraps runner modules with isolated instance state via extend
lib/legion/gaia/sensory_buffer.rb # Thread-safe signal queue (max 1000, normalized)
lib/legion/gaia/actors/heartbeat.rb # Every-1s actor, drains buffer and drives tick
```

## Architecture

- `Legion::Gaia.boot` creates SensoryBuffer and Registry, runs discovery
- `Registry#discover` walks `PHASE_MAP`, resolves runner classes via `Legion::Extensions`, wraps in `RunnerHost`
- `Legion::Gaia.heartbeat` drains buffer, calls `tick_host.execute_tick(signals:, phase_handlers:)`
- Heartbeat actor calls `heartbeat` every 1s (configurable via settings)
- Graceful degradation: if lex-tick not loaded, heartbeat returns `{ error: :no_tick_extension }` and retries next tick

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

## Future (Phase 2-5)

- Channel abstraction: InputFrame, OutputFrame, ChannelAdapter, ChannelRegistry
- CLI adapter, Teams adapter (Bot Framework), Slack adapter
- Central router mode (hub-and-spoke via RabbitMQ)
- Session continuity across channels
