# Legion::Gaia

Cognitive coordination layer for the LegionIO framework. GAIA is the mind that inhabits the Legion body.

GAIA sits on top of LegionIO's infrastructure and coordinates all agentic subordinate functions. It drives the tick cycle, manages extension discovery and wiring, and provides the channel abstraction for multi-interface communication.

## Architecture

```
             GAIA (legion-gaia)
              |
    +---------+---------+
    |         |         |
 Registry  SensoryBuffer  Heartbeat Actor
    |                        |
 PhaseWiring              drives tick
    |                     every 1s
 RunnerHost(s)
    |
 [lex-tick, lex-emotion, lex-memory, lex-identity, ...]
```

**Registry** discovers loaded agentic extensions, resolves their runner modules, and builds phase handlers that map cognitive phases to extension functions.

**SensoryBuffer** is a thread-safe queue that collects inbound signals (human input, system events, ambient data) between heartbeat ticks.

**Heartbeat** actor drains the buffer and drives the tick cycle once per second, executing all wired cognitive phases in sequence.

## Installation

```ruby
gem 'legion-gaia'
```

## Usage

GAIA boots automatically when detected by LegionIO. Manual usage:

```ruby
require 'legion/gaia'

Legion::Gaia.boot
Legion::Gaia.sensory_buffer.push({ value: 'hello', source_type: :human_direct, salience: 0.9 })
result = Legion::Gaia.heartbeat
Legion::Gaia.status
Legion::Gaia.shutdown
```

## Configuration

Via `legion-settings` or `Legion::Gaia::Settings.default`:

```yaml
gaia:
  enabled: true
  heartbeat_interval: 1
  channels:
    cli:
      enabled: true
    teams:
      enabled: false
    slack:
      enabled: false
  router:
    mode: false
    allowed_worker_ids: []
  session:
    persistence: auto
    ttl: 86400
  output:
    mobile_max_length: 500
    suggest_channel_switch: true
```

## Cognitive Phases

GAIA wires 19 phases across two cycles:

**Active Tick (12 phases):** sensory processing, emotional evaluation, memory retrieval, identity entropy check, working memory integration, procedural check, prediction engine, mesh interface, gut instinct, action selection, memory consolidation, post-tick reflection.

**Dream Cycle (7 phases):** memory audit, association walk, contradiction resolution, agenda formation, consolidation commit, dream reflection, dream narration.

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

Apache-2.0
