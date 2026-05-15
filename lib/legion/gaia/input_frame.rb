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
      def initialize(
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

      def to_signal
        {
          value:        content,
          source_type:  metadata[:source_type] || :ambient,
          salience:     salience,
          channel_id:   channel_id,
          frame_id:     id,
          received_at:  received_at,
          principal_id: resolved_principal_id
        }
      end
    end
  end
end
