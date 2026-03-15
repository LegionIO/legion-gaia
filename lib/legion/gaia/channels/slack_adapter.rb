# frozen_string_literal: true

require_relative 'slack/signing_verifier'

module Legion
  module Gaia
    module Channels
      class SlackAdapter < ChannelAdapter
        CAPABILITIES = %i[rich_text threads reactions mentions file_attachment].freeze

        attr_reader :signing_secret, :bot_token

        def initialize(signing_secret: nil, bot_token: nil, default_webhook: nil)
          super(channel_id: :slack, capabilities: CAPABILITIES)
          @signing_secret = signing_secret
          @bot_token = bot_token
          @default_webhook = default_webhook
        end

        def translate_inbound(event)
          return nil unless event.is_a?(Hash)

          user = event['user'] || event[:user]
          InputFrame.new(
            content: strip_bot_mention(event['text'] || event[:text] || ''),
            channel_id: :slack,
            content_type: :text,
            channel_capabilities: CAPABILITIES,
            device_context: { platform: :desktop, input_method: :keyboard },
            auth_context: { user_id: user, team_id: event['team'] || event[:team], identity: user },
            metadata: build_slack_metadata(event)
          )
        end

        def translate_outbound(output_frame)
          content = output_frame.content.to_s
          thread_ts = output_frame.metadata[:slack_thread_ts]
          channel = output_frame.metadata[:slack_channel]

          result = { text: content }
          result[:thread_ts] = thread_ts if thread_ts
          result[:channel] = channel if channel
          result
        end

        def deliver(rendered_content, webhook: nil)
          target_webhook = webhook || @default_webhook
          return deliver_via_api(rendered_content) if @bot_token && !target_webhook

          deliver_via_webhook(rendered_content, target_webhook)
        end

        def verify_request(signing_secret: nil, timestamp: nil, body: nil, signature: nil)
          secret = signing_secret || @signing_secret
          return { valid: false, error: :no_signing_secret } unless secret

          Slack::SigningVerifier.verify(
            signing_secret: secret,
            timestamp: timestamp,
            body: body,
            signature: signature
          )
        end

        private

        def build_slack_metadata(event)
          {
            source_type: :human_direct,
            salience: 0.9,
            slack_channel: event['channel'] || event[:channel],
            slack_ts: event['ts'] || event[:ts],
            slack_thread_ts: event['thread_ts'] || event[:thread_ts],
            event_type: event['type'] || event[:type]
          }
        end

        def strip_bot_mention(text)
          text.gsub(/<@[A-Z0-9]+>/, '').strip
        end

        def deliver_via_webhook(content, webhook)
          unless slack_runner_available?
            return { error: :slack_runner_not_available,
                     message: 'lex-slack Chat runner not loaded' }
          end

          message = content.is_a?(Hash) ? content[:text] : content.to_s
          Legion::Extensions::Slack::Runners::Chat.send(message: message, webhook: webhook)
        end

        def deliver_via_api(_content)
          { error: :not_implemented, message: 'Bot token API delivery not yet implemented' }
        end

        def slack_runner_available?
          defined?(Legion::Extensions::Slack::Runners::Chat)
        end
      end
    end
  end
end
