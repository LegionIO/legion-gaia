# frozen_string_literal: true

module Legion
  module Gaia
    module Proactive
      class << self
        def send_message(channel_id:, content:, user_id: nil, content_type: :text)
          registry = Legion::Gaia.channel_registry
          return { error: 'channel registry not available' } unless registry

          adapter = registry.adapter_for(channel_id)
          return { error: "no adapter for channel: #{channel_id}" } unless adapter

          output = OutputFrame.new(
            content: content,
            content_type: content_type,
            channel_id: channel_id,
            metadata: { proactive: true, target_user: user_id }
          )

          registry.deliver(output)
          { sent: true, frame_id: output.id, channel: channel_id }
        rescue StandardError => e
          { error: e.message }
        end

        def send_to_user(user_id:, content:, channel_id: nil, content_type: :text)
          registry = Legion::Gaia.channel_registry
          return { error: 'channel registry not available' } unless registry

          if channel_id
            deliver_to_user_on_channel(
              registry: registry,
              user_id: user_id,
              channel_id: channel_id,
              content: content,
              content_type: content_type
            )
          else
            deliver_to_user_all_channels(
              registry: registry,
              user_id: user_id,
              content: content,
              content_type: content_type
            )
          end
        rescue StandardError => e
          { error: e.message }
        end

        def send_notification(content:, priority: :normal, channel_id: nil, user_id: nil)
          registry = Legion::Gaia.channel_registry
          return { error: 'channel registry not available' } unless registry

          output_router = Legion::Gaia.output_router
          return { error: 'output router not available' } unless output_router

          channels = channel_id ? [channel_id] : registry.active_channels
          results = {}

          channels.each do |ch|
            adapter = registry.adapter_for(ch)
            next unless adapter

            frame = OutputFrame.new(
              content: content,
              channel_id: ch,
              metadata: { proactive: true, priority: priority, target_user: user_id }
            )
            results[ch] = output_router.route(frame)
          end

          results
        rescue StandardError => e
          { error: e.message }
        end

        def start_conversation(channel_id:, user_id:, content:)
          registry = Legion::Gaia.channel_registry
          return { error: 'channel registry not available' } unless registry

          adapter = registry.adapter_for(channel_id)
          return { error: "no adapter for channel: #{channel_id}" } unless adapter

          frame = OutputFrame.new(
            content: content,
            channel_id: channel_id,
            metadata: { proactive: true, target_user: user_id, start_conversation: true }
          )

          if adapter.respond_to?(:deliver_proactive)
            result = adapter.deliver_proactive(frame)
            return result if result.is_a?(Hash) && result[:error]

          else
            registry.deliver(frame)
          end
          { started: true, channel: channel_id, user_id: user_id }
        rescue StandardError => e
          { error: e.message }
        end

        def broadcast(content:, channels: nil)
          registry = Legion::Gaia.channel_registry
          return { error: 'channel registry not available' } unless registry

          targets = channels || registry.active_channels
          results = {}
          targets.each do |ch|
            results[ch] = send_message(channel_id: ch, content: content)
          end
          results
        end

        private

        def deliver_to_user_on_channel(registry:, user_id:, channel_id:, content:, content_type:)
          adapter = registry.adapter_for(channel_id)
          return { error: "no adapter for channel: #{channel_id}" } unless adapter

          frame = OutputFrame.new(
            content: content,
            content_type: content_type,
            channel_id: channel_id,
            metadata: { proactive: true, target_user: user_id }
          )

          if adapter.respond_to?(:deliver_proactive)
            result = adapter.deliver_proactive(frame)
            return result if result.is_a?(Hash) && result[:error]
          else
            registry.deliver(frame)
          end

          { sent: true, frame_id: frame.id, channel: channel_id, user_id: user_id }
        end

        def deliver_to_user_all_channels(registry:, user_id:, content:, content_type:)
          channels = registry.active_channels
          return { error: 'no active channels' } if channels.empty?

          results = {}
          channels.each do |ch|
            results[ch] = deliver_to_user_on_channel(
              registry: registry,
              user_id: user_id,
              channel_id: ch,
              content: content,
              content_type: content_type
            )
          end
          { sent: true, results: results }
        end
      end
    end
  end
end
