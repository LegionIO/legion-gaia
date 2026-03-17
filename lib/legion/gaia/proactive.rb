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
      end
    end
  end
end
