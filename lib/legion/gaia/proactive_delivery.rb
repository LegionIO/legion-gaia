# frozen_string_literal: true

module Legion
  module Gaia
    module ProactiveDelivery
      private

      def deliver_to_user_on_channel(registry:, user_id:, channel_id:, content:, content_type:)
        adapter = registry.adapter_for(channel_id)
        return no_adapter_result(channel_id: channel_id, status_key: :sent, user_id: user_id) unless adapter

        frame = OutputFrame.new(
          content: content,
          content_type: content_type,
          channel_id: channel_id,
          metadata: { proactive: true, target_user: user_id }
        )

        result = if adapter.respond_to?(:deliver_proactive)
                   adapter.deliver_proactive(frame)
                 else
                   registry.deliver(frame)
                 end

        normalize_delivery_outcome(
          result,
          status_key: :sent,
          frame_id: frame.id,
          channel_id: channel_id,
          user_id: user_id
        )
      end

      def deliver_to_user_all_channels(registry:, user_id:, content:, content_type:)
        channels = registry.active_channels
        return { sent: false, error: 'no active channels', reason: :no_active_channels } if channels.empty?

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

        sent = results.values.all? { |value| delivery_success?(value) }
        log.error("Proactive.deliver_to_user_all_channels encountered channel errors user_id=#{user_id}") unless sent

        {
          sent: sent,
          reason: sent ? nil : fanout_failure_reason(results),
          results: results
        }.compact
      end

      def delivery_success?(result)
        return !!result unless result.is_a?(Hash)
        return false if result[:error]
        return result[:sent] unless result[:sent].nil?
        return result[:started] unless result[:started].nil?
        return result[:delivered] unless result[:delivered].nil?

        true
      end

      def normalize_delivery_outcome(result, status_key:, frame_id:, channel_id:, user_id: nil)
        outcome = result.is_a?(Hash) ? result.dup : {}
        outcome[:frame_id] ||= frame_id if frame_id
        outcome[:channel] ||= channel_id if channel_id
        outcome[:channel_id] ||= channel_id if channel_id
        outcome[:user_id] ||= user_id if user_id
        outcome[status_key] = delivery_success?(result)
        outcome[:delivered] = outcome[status_key] if !outcome.key?(:delivered) && status_key == :delivered
        outcome
      end

      def no_adapter_result(channel_id:, status_key:, user_id: nil)
        {
          status_key => false,
          delivered: false,
          reason: :no_adapter,
          error: "no adapter for channel: #{channel_id}",
          channel: channel_id,
          channel_id: channel_id,
          user_id: user_id
        }.compact
      end

      def delivery_failure_label(result)
        return :delivery_failed unless result.is_a?(Hash)

        result[:error] || result[:reason] || :delivery_failed
      end

      def fanout_failure_reason(results)
        successes = results.values.count { |value| delivery_success?(value) }
        successes.zero? ? :delivery_failed : :partial_failure
      end
    end
  end
end
