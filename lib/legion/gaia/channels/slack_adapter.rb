# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'legion/logging/helper'
require_relative 'slack/signing_verifier'

module Legion
  module Gaia
    module Channels
      class SlackAdapter < ChannelAdapter
        include Legion::Logging::Helper

        CAPABILITIES = %i[rich_text threads reactions mentions file_attachment].freeze

        attr_reader :signing_secret, :bot_token

        def self.from_settings(settings)
          return nil unless settings&.dig(:channels, :slack, :enabled)

          new(
            signing_secret: settings.dig(:channels, :slack, :signing_secret),
            bot_token: settings.dig(:channels, :slack, :bot_token),
            default_webhook: settings.dig(:channels, :slack, :default_webhook)
          )
        end

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
          log.info(
            'SlackAdapter delivering ' \
            "mode=#{@bot_token && !target_webhook ? 'api' : 'webhook'} channel=#{channel_id}"
          )
          return deliver_via_api(rendered_content) if @bot_token && !target_webhook

          deliver_via_webhook(rendered_content, target_webhook)
        end

        def deliver_proactive(output_frame)
          user_id = output_frame.metadata[:target_user]
          return { error: :no_target_user } unless user_id

          dm_result = open_dm(user_id: user_id)
          return dm_result if dm_result.is_a?(Hash) && dm_result[:error]

          channel = dm_result[:channel_id]
          rendered = translate_outbound(output_frame).merge(channel: channel)
          log.info("SlackAdapter proactive delivery user_id=#{user_id} channel=#{channel}")
          deliver_via_api_to_channel(rendered)
        end

        def open_dm(user_id:)
          return { error: :no_bot_token } unless @bot_token
          return { error: :slack_runner_not_available } unless slack_runner_available?

          result = Legion::Extensions::Slack::Runners::Chat.open_dm(
            user_id: user_id,
            token: @bot_token
          )
          return result if result.is_a?(Hash) && result[:error]

          channel_id = result[:channel_id] || result['channel']&.dig('id') || result['channel']
          log.info("SlackAdapter opened DM user_id=#{user_id} channel=#{channel_id}")
          { channel_id: channel_id }
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'gaia.channels.slack_adapter.open_dm', user_id: user_id)
          { error: :open_dm_failed, message: e.message }
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
            log.error('SlackAdapter deliver_via_webhook failed error=slack_runner_not_available')
            return { error: :slack_runner_not_available,
                     message: 'lex-slack Chat runner not loaded' }
          end

          message = content.is_a?(Hash) ? content[:text] : content.to_s
          log.info("SlackAdapter delivering via webhook message_length=#{message.length}")
          Legion::Extensions::Slack::Runners::Chat.send(message: message, webhook: webhook)
        end

        def deliver_via_api(content)
          return { error: :no_bot_token } unless @bot_token

          text = content.is_a?(Hash) ? content[:text] : content.to_s
          channel = (content.is_a?(Hash) && content[:channel]) || @channel_id.to_s
          post_to_slack_api(channel: channel, text: text)
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'gaia.channels.slack_adapter.deliver_via_api',
                              channel: channel)
          { error: :network_error, message: e.message }
        end

        def post_to_slack_api(channel:, text:)
          uri = URI('https://slack.com/api/chat.postMessage')
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true

          request = Net::HTTP::Post.new(uri.path)
          request['Authorization'] = "Bearer #{@bot_token}"
          request['Content-Type'] = 'application/json'
          request.body = ::JSON.generate({ channel: channel, text: text })

          response = http.request(request)
          parsed = ::JSON.parse(response.body, symbolize_names: true)

          if parsed[:ok]
            log.info("SlackAdapter delivered via API channel=#{channel}")
            { delivered: true, ts: parsed[:ts] }
          else
            log.error("SlackAdapter API delivery failed channel=#{channel} error=#{parsed[:error] || :unknown_error}")
            { error: parsed[:error] || :unknown_error }
          end
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'gaia.channels.slack_adapter.post_to_slack_api',
                              channel: channel)
          { error: :network_error, message: e.message }
        end

        def deliver_via_api_to_channel(content)
          unless slack_runner_available?
            log.error('SlackAdapter deliver_via_api_to_channel failed error=slack_runner_not_available')
            return { error: :slack_runner_not_available,
                     message: 'lex-slack Chat runner not loaded' }
          end

          message = content.is_a?(Hash) ? content[:text] : content.to_s
          channel = content.is_a?(Hash) ? content[:channel] : nil
          log.info("SlackAdapter sending proactive API message channel=#{channel}")
          Legion::Extensions::Slack::Runners::Chat.send(
            message: message,
            channel: channel,
            token: @bot_token
          )
        end

        def slack_runner_available?
          defined?(Legion::Extensions::Slack::Runners::Chat)
        end
      end
    end
  end
end
