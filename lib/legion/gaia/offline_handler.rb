# frozen_string_literal: true

module Legion
  module Gaia
    module OfflineHandler
      DEFAULT_OFFLINE_MESSAGE = 'The agent is currently offline. Your message has been queued.'

      class << self
        def handle_offline_delivery(input_frame, worker_id:)
          queue_message(input_frame, worker_id)
          notify_sender(input_frame)
          { queued: true, worker_id: worker_id }
        end

        def agent_online?(worker_id)
          presence = presence_store[worker_id]
          return false unless presence

          (Time.now - presence[:last_seen]) < offline_threshold
        end

        def record_presence(worker_id)
          presence_store[worker_id] = { last_seen: Time.now }
        end

        def pending_count(worker_id)
          pending_store[worker_id]&.size || 0
        end

        def drain_pending(worker_id)
          pending_store.delete(worker_id) || []
        end

        def reset!
          @presence_store = {}
          @pending_store = {}
        end

        private

        def queue_message(frame, worker_id)
          pending_store[worker_id] ||= []
          pending_store[worker_id] << { frame: frame, queued_at: Time.now }
        end

        def notify_sender(frame)
          return unless frame.respond_to?(:channel_id)

          registry = Legion::Gaia.channel_registry
          return unless registry

          output = OutputFrame.new(
            in_reply_to: frame.respond_to?(:id) ? frame.id : nil,
            content: DEFAULT_OFFLINE_MESSAGE,
            channel_id: frame.channel_id,
            session_continuity_id: frame.respond_to?(:session_continuity_id) ? frame.session_continuity_id : nil
          )
          registry.deliver(output)
        rescue StandardError => e
          Legion::Logging.warn("OfflineHandler notify_sender failed: #{e.message}") if defined?(Legion::Logging)
          nil
        end

        def offline_threshold
          if Legion.const_defined?('Settings')
            Legion::Settings.dig(:gaia, :offline_threshold) || 60
          else
            60
          end
        rescue StandardError => e
          if defined?(Legion::Logging)
            Legion::Logging.debug("OfflineHandler offline_threshold settings unavailable, using default: #{e.message}")
          end
          60
        end

        def presence_store
          @presence_store ||= {}
        end

        def pending_store
          @pending_store ||= {}
        end
      end
    end
  end
end
