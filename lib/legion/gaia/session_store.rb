# frozen_string_literal: true

require 'securerandom'

module Legion
  module Gaia
    class SessionStore
      UUID_PATTERN = /\A[0-9a-f]{8}-/i

      Session = ::Data.define(:id, :identity, :channel_history, :created_at, :last_active_at) do
        def initialize(identity:, id: SecureRandom.uuid, channel_history: [],
                       created_at: Time.now.utc, last_active_at: Time.now.utc)
          super
        end
      end

      def initialize(ttl: 86_400)
        @sessions = {}
        @identity_index = {}
        @canonical_to_uuid = {}
        @ttl = ttl
        @mutex = Mutex.new
      end

      def find_or_create(identity:, canonical_name: nil)
        @mutex.synchronize do
          normalized = normalize_identity(identity)
          session_id = resolve_session_id(normalized, canonical_name: canonical_name)

          if session_id && @sessions[session_id]
            session = @sessions[session_id]
            return session unless expired?(session)

            remove_unlocked(session_id)
          end

          session = Session.new(identity: normalized)
          @sessions[session.id] = session
          @identity_index[normalized] = session.id
          @canonical_to_uuid[canonical_name.to_s.downcase] = normalized if canonical_name && uuid?(normalized)
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

      def uuid?(identity)
        UUID_PATTERN.match?(identity.to_s)
      end

      def normalize_identity(identity)
        str = identity.to_s
        uuid?(str) ? str : str.downcase
      end

      def resolve_session_id(normalized_identity, canonical_name:)
        existing = @identity_index[normalized_identity]
        return existing if existing

        return nil unless canonical_name && uuid?(normalized_identity)

        canonical_key = canonical_name.to_s.downcase
        # Check if there is an existing string-keyed session for this canonical_name
        old_session_id = @identity_index[canonical_key]
        return nil unless old_session_id && @sessions[old_session_id]

        # Migrate string-keyed session to UUID key
        @identity_index.delete(canonical_key)
        @identity_index[normalized_identity] = old_session_id
        @canonical_to_uuid[canonical_key] = normalized_identity
        old_session_id
      end

      def expired?(session)
        (Time.now.utc - session.last_active_at) > @ttl
      end

      def remove_unlocked(session_id)
        session = @sessions.delete(session_id)
        if session
          removed_keys = @identity_index.select { |_, v| v == session_id }.keys
          removed_keys.each { |k| @identity_index.delete(k) }
          @canonical_to_uuid.delete_if { |_, v| removed_keys.include?(v) }
        end
        session
      end
    end
  end
end
