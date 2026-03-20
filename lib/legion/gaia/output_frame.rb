# frozen_string_literal: true

require 'securerandom'

module Legion
  module Gaia
    OutputFrame = ::Data.define(
      :id,
      :in_reply_to,
      :content,
      :content_type,
      :channel_id,
      :session_continuity_id,
      :channel_hints,
      :metadata,
      :created_at
    ) do
      def initialize(
        content:,
        channel_id:,
        id: SecureRandom.uuid,
        in_reply_to: nil,
        content_type: :text,
        session_continuity_id: nil,
        channel_hints: {},
        metadata: {},
        created_at: Time.now.utc
      )
        super
      end

      def text?
        content_type == :text
      end

      def suggest_richer_channel?
        channel_hints[:suggest_channel_switch] == true
      end

      def truncated?
        channel_hints[:truncated] == true
      end
    end
  end
end
