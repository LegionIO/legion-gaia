# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module Proactive
      extend Legion::Logging::Helper

      class << self
        def send_message(channel_id:, content:, user_id: nil, content_type: :text)
          registry = Legion::Gaia.channel_registry
          unless registry
            log.error("Proactive.send_message failed channel=#{channel_id} error=channel_registry_not_available")
            return { error: 'channel registry not available' }
          end

          adapter = registry.adapter_for(channel_id)
          unless adapter
            log.error("Proactive.send_message failed channel=#{channel_id} error=no_adapter")
            return { error: "no adapter for channel: #{channel_id}" }
          end

          output = OutputFrame.new(
            content: content,
            content_type: content_type,
            channel_id: channel_id,
            metadata: { proactive: true, target_user: user_id }
          )

          result = registry.deliver(output)
          if result.is_a?(Hash) && result[:error]
            log.error("Proactive.send_message failed channel=#{channel_id} error=#{result[:error]}")
            return result
          end

          log.info("Proactive.send_message sent frame_id=#{output.id} channel=#{channel_id} user_id=#{user_id}")
          { sent: true, frame_id: output.id, channel: channel_id }
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'gaia.proactive.send_message',
                              channel_id: channel_id, user_id: user_id)
          { error: e.message }
        end

        def send_to_user(user_id:, content:, channel_id: nil, content_type: :text)
          registry = Legion::Gaia.channel_registry
          unless registry
            log.error("Proactive.send_to_user failed user_id=#{user_id} error=channel_registry_not_available")
            return { error: 'channel registry not available' }
          end

          result = if channel_id
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
          if result.is_a?(Hash) && result[:error]
            log.error(
              'Proactive.send_to_user failed ' \
              "user_id=#{user_id} channel_id=#{channel_id || 'all'} error=#{result[:error]}"
            )
          else
            log.info("Proactive.send_to_user completed user_id=#{user_id} channel_id=#{channel_id || 'all'}")
          end
          result
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'gaia.proactive.send_to_user',
                              user_id: user_id, channel_id: channel_id)
          { error: e.message }
        end

        def send_notification(content:, priority: :normal, channel_id: nil, user_id: nil)
          registry = Legion::Gaia.channel_registry
          unless registry
            log.error('Proactive.send_notification failed error=channel_registry_not_available')
            return { error: 'channel registry not available' }
          end

          output_router = Legion::Gaia.output_router
          unless output_router
            log.error('Proactive.send_notification failed error=output_router_not_available')
            return { error: 'output router not available' }
          end

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

          log.info(
            'Proactive.send_notification routed ' \
            "channels=#{channels.size} priority=#{priority} user_id=#{user_id}"
          )
          results
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'gaia.proactive.send_notification',
                              priority: priority, channel_id: channel_id, user_id: user_id)
          { error: e.message }
        end

        def start_conversation(channel_id:, user_id:, content:)
          registry = Legion::Gaia.channel_registry
          unless registry
            log.error(
              'Proactive.start_conversation failed ' \
              "channel=#{channel_id} user_id=#{user_id} error=channel_registry_not_available"
            )
            return { error: 'channel registry not available' }
          end

          adapter = registry.adapter_for(channel_id)
          unless adapter
            log.error("Proactive.start_conversation failed channel=#{channel_id} user_id=#{user_id} error=no_adapter")
            return { error: "no adapter for channel: #{channel_id}" }
          end

          frame = OutputFrame.new(
            content: content,
            channel_id: channel_id,
            metadata: { proactive: true, target_user: user_id, start_conversation: true }
          )

          if adapter.respond_to?(:deliver_proactive)
            result = adapter.deliver_proactive(frame)
            if result.is_a?(Hash) && result[:error]
              log.error(
                'Proactive.start_conversation failed ' \
                "channel=#{channel_id} user_id=#{user_id} error=#{result[:error]}"
              )
              return result
            end

          else
            registry.deliver(frame)
          end
          log.info("Proactive.start_conversation started channel=#{channel_id} user_id=#{user_id} frame_id=#{frame.id}")
          { started: true, channel: channel_id, user_id: user_id }
        rescue StandardError => e
          handle_exception(e, level: :error, operation: 'gaia.proactive.start_conversation',
                              channel_id: channel_id, user_id: user_id)
          { error: e.message }
        end

        def broadcast(content:, channels: nil)
          registry = Legion::Gaia.channel_registry
          unless registry
            log.error('Proactive.broadcast failed error=channel_registry_not_available')
            return { error: 'channel registry not available' }
          end

          targets = channels || registry.active_channels
          results = {}
          targets.each do |ch|
            results[ch] = send_message(channel_id: ch, content: content)
          end
          log.info("Proactive.broadcast completed channels=#{targets.size}")
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
          if results.values.any? { |value| value.is_a?(Hash) && value[:error] }
            log.error("Proactive.deliver_to_user_all_channels encountered channel errors user_id=#{user_id}")
          end
          { sent: true, results: results }
        end
      end
    end
  end
end
