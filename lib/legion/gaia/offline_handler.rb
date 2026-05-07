# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module OfflineHandler
      extend Legion::Logging::Helper

      DEFAULT_OFFLINE_MESSAGE = 'The agent is currently offline. Your message has been queued.'

      class << self
        def handle_offline_delivery(input_frame, worker_id:)
          queue_message(input_frame, worker_id)
          notify_sender(input_frame)
          log.info(
            'OfflineHandler queued ' \
            "frame_id=#{input_frame.respond_to?(:id) ? input_frame.id : 'unknown'} worker_id=#{worker_id}"
          )
          { queued: true, worker_id: worker_id }
        end

        def agent_online?(worker_id)
          presence = mutex.synchronize { presence_store[worker_id] }
          return false unless presence

          (Time.now - presence[:last_seen]) < offline_threshold
        end

        def record_presence(worker_id)
          mutex.synchronize { presence_store[worker_id] = { last_seen: Time.now } }
          log.debug("OfflineHandler recorded presence worker_id=#{worker_id}")
        end

        def pending_count(worker_id)
          mutex.synchronize { pending_store[worker_id]&.size || 0 }
        end

        def drain_pending(worker_id)
          drained = mutex.synchronize { pending_store.delete(worker_id) || [] }
          log.info("OfflineHandler drained pending worker_id=#{worker_id} count=#{drained.size}") if drained.any?
          drained
        end

        def reset!
          mutex.synchronize do
            @presence_store = {}
            @pending_store = {}
          end
        end

        private

        def queue_message(frame, worker_id)
          mutex.synchronize do
            pending_store[worker_id] ||= []
            pending_store[worker_id] << { frame: frame, queued_at: Time.now }
          end
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
          log.info("OfflineHandler notified sender frame_id=#{output.id} channel=#{frame.channel_id}")
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'gaia.offline_handler.notify_sender',
                              channel_id: frame.respond_to?(:channel_id) ? frame.channel_id : nil)
          nil
        end

        def offline_threshold
          if Legion.const_defined?(:Settings, false)
            Legion::Settings.dig(:gaia, :offline_threshold) || 60
          else
            60
          end
        rescue StandardError => e
          handle_exception(e, level: :debug, operation: 'gaia.offline_handler.offline_threshold')
          60
        end

        def presence_store
          @presence_store ||= {}
        end

        def pending_store
          @pending_store ||= {}
        end

        def mutex
          @mutex ||= Mutex.new
        end
      end
    end
  end
end
