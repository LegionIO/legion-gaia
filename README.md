# Legion::Gaia

Cognitive coordination layer for the LegionIO framework. GAIA is the mind that inhabits the Legion body.

**Version**: 0.9.2

GAIA sits on top of LegionIO's infrastructure and coordinates all agentic subordinate functions. It drives the tick cycle, manages extension discovery and wiring, and provides the channel abstraction for multi-interface communication.

## Architecture

```
Human Input                              Human Output
    |                                        ^
    v                                        |
ChannelAdapter (CLI/Teams/Slack)         ChannelAdapter
    |                                        ^
    v                                        |
InputFrame (Data.define, immutable)      OutputFrame
    |                                        ^
    v                                        |
Legion::Gaia.ingest                      OutputRouter -> NotificationGate -> Renderer
    |                                        ^
    v                                        |
SensoryBuffer -----> Heartbeat (1s) --> Cognitive Pipeline
                         |
                    PhaseWiring (19 phases)
                         |
                    Registry -> RunnerHost(s)
                         |
                    [lex-tick, lex-emotion, lex-memory, ...]
```

**Registry** discovers loaded agentic extensions, resolves their runner modules, and builds phase handlers that map cognitive phases to extension functions.

**SensoryBuffer** is a thread-safe queue that collects inbound signals (human input, system events, ambient data) between heartbeat ticks.

**Heartbeat** actor drains the buffer and drives the tick cycle once per second, executing all wired cognitive phases in sequence.

**Channel Abstraction** provides multi-interface communication through thin adapters. Each adapter translates format (not content) between channel-native I/O and GAIA's universal InputFrame/OutputFrame format.

## Installation

```ruby
gem 'legion-gaia'
```

## Usage

GAIA boots automatically when detected by LegionIO. Manual usage:

```ruby
require 'legion/gaia'

# Boot GAIA (creates registry, sensory buffer, channel infrastructure)
Legion::Gaia.boot

# Ingest input through the channel abstraction
cli = Legion::Gaia.channel_registry.adapter_for(:cli)
frame = cli.translate_inbound('hello world')
Legion::Gaia.ingest(frame)

# Drive the cognitive tick
result = Legion::Gaia.heartbeat

# Send output through a channel
Legion::Gaia.respond(content: 'response text', channel_id: :cli)

# Check status
Legion::Gaia.status
# => { started: true, extensions_loaded: 0, wired_phases: 0, active_channels: [:cli], ... }

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

## Channel Adapters

| Adapter | Status | Capabilities |
|---------|--------|-------------|
| CLI | Built | Rich text, inline code, syntax highlighting, file attachment |
| Teams | Built | Adaptive cards, proactive messaging, mobile/desktop, Bot Framework auth |
| Slack | Built | Rich text, threads, reactions, mentions, file attachment |

## Central Router (Hub-and-Spoke)

For deployments where agents run behind firewalls (laptops, internal servers), a stateless central router bridges public endpoints to agents via RabbitMQ.

```ruby
# Router mode — public server, no brain
Legion::Gaia.boot(mode: :router)

# Agent mode with bridge — laptop behind firewall
Legion::Gaia.boot  # auto-detects router.mode and router.worker_id from settings
```

```
Bot Framework -> Central Router -> RabbitMQ -> Agent (GAIA) -> RabbitMQ -> Central Router -> Teams
```

## Notification Gate

Three-layer evaluation pipeline between OutputRouter and channel delivery:

1. **ScheduleEvaluator** — Config-driven quiet hours (time windows with day/time/timezone)
2. **PresenceEvaluator** — Teams presence status (maps availability to minimum priority thresholds)
3. **BehavioralEvaluator** — Learned signals (arousal from lex-emotion, idle time from lex-temporal)

Priority override ensures critical/urgent messages always deliver. Delayed messages queue in a thread-safe DelayQueue and re-evaluate each heartbeat tick.

```yaml
gaia:
  notifications:
    enabled: true
    quiet_hours:
      enabled: true
      schedule:
        - days: [mon, tue, wed, thu, fri]
          start: "21:00"
          end: "07:00"
          timezone: America/Chicago
    priority_override: urgent
    delay_queue_max: 100
    max_delay: 14400
```

## Development

```bash
bundle install
bundle exec rspec    # 319 specs
bundle exec rubocop  # 0 offenses
```

## License

Apache-2.0
