# frozen_string_literal: true

require 'securerandom'

module Legion
  module Gaia
    include Legion::Logging::Helper

    InputFrame = ::Data.define(
      :id,
      :content,
      :content_type,
      :channel_id,
      :channel_capabilities,
      :device_context,
      :session_continuity_id,
      :auth_context,
      :metadata,
      :received_at,
      :principal_id
    ) do
      def initialize( # rubocop:disable Metrics/ParameterLists
        content:,
        channel_id:,
        id: SecureRandom.uuid,
        content_type: :text,
        channel_capabilities: [],
        device_context: {},
        session_continuity_id: nil,
        auth_context: {},
        metadata: {},
        received_at: Time.now.utc,
        principal_id: nil
      )
        super
      end

      def text?
        content_type == :text
      end

      def human_direct?
        metadata[:source_type] == :human_direct
      end

      def salience
        metadata[:salience] || 0.0
      end

      def resolved_principal_id
        principal_id || auth_context&.dig(:principal_id)
      end

      def authenticated_identity
        context = auth_context || {}
        explicit = resolved_principal_id || context[:identity]
        return explicit unless explicit.to_s.strip.empty?

        case channel_id.to_s
        when 'teams'
          user = context[:aad_object_id] || context[:user_id]
          scope = context[:tenant_id]
        when 'slack'
          user = context[:user_id]
          scope = context[:team_id]
        end
        return nil if user.to_s.empty? || scope.to_s.empty?

        "#{channel_id}:#{scope}:#{user}"
      end

      def to_signal
        identity = authenticated_identity
        prediction = metadata[:prediction_request]
        signal_metadata = if prediction.is_a?(Hash) && identity
                            { prediction_request: prediction.slice(:domain, :description, :expected_outcome) }
                          else
                            {}
                          end
        {
          value: content,
          source_type: metadata[:source_type] || :ambient,
          salience: salience,
          channel_id: channel_id,
          frame_id: id,
          received_at: received_at,
          principal_id: resolved_principal_id,
          identity: identity,
          conversation_id: metadata[:conversation_id],
          exchange_id: metadata[:exchange_id],
          session_continuity_id: session_continuity_id,
          metadata: signal_metadata
        }
      end
    end
  end
end
