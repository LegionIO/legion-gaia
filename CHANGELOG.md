# Changelog

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
