# Changelog

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
