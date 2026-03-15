# frozen_string_literal: true

require 'securerandom'

module Legion
  module Gaia
    class SessionStore
      Session = Data.define(:id, :identity, :channel_history, :created_at, :last_active_at) do
        def initialize(identity:, id: SecureRandom.uuid, channel_history: [],
                       created_at: Time.now.utc, last_active_at: Time.now.utc)
          super
        end
      end

      def initialize(ttl: 86_400)
        @sessions = {}
        @identity_index = {}
        @ttl = ttl
        @mutex = Mutex.new
      end

      def find_or_create(identity:)
        @mutex.synchronize do
          session_id = @identity_index[identity]
          if session_id && @sessions[session_id]
            session = @sessions[session_id]
            return session unless expired?(session)

            remove_unlocked(session_id)
          end

          session = Session.new(identity: identity)
          @sessions[session.id] = session
          @identity_index[identity] = session.id
          session
        end
      end

      def touch(session_id, channel_id: nil)
        @mutex.synchronize do
          session = @sessions[session_id]
          return nil unless session

          history = channel_id ? (session.channel_history + [channel_id]).uniq : session.channel_history
          updated = Session.new(
            id: session.id,
            identity: session.identity,
            channel_history: history,
            created_at: session.created_at,
            last_active_at: Time.now.utc
          )
          @sessions[session_id] = updated
          updated
        end
      end

      def get(session_id)
        @mutex.synchronize { @sessions[session_id] }
      end

      def remove(session_id)
        @mutex.synchronize { remove_unlocked(session_id) }
      end

      def size
        @mutex.synchronize { @sessions.size }
      end

      def prune_expired
        @mutex.synchronize do
          expired_ids = @sessions.select { |_, s| expired?(s) }.keys
          expired_ids.each { |id| remove_unlocked(id) }
          expired_ids.size
        end
      end

      private

      def expired?(session)
        (Time.now.utc - session.last_active_at) > @ttl
      end

      def remove_unlocked(session_id)
        session = @sessions.delete(session_id)
        @identity_index.delete(session.identity) if session
        session
      end
    end
  end
end
