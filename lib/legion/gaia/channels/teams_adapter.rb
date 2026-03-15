# frozen_string_literal: true

require_relative 'teams/bot_framework_auth'
require_relative 'teams/conversation_store'
require_relative 'teams/webhook_handler'

module Legion
  module Gaia
    module Channels
      class TeamsAdapter < ChannelAdapter
        CAPABILITIES = %i[rich_text adaptive_cards proactive_messaging mobile desktop mentions].freeze
        MOBILE_CAPABILITIES = %i[rich_text adaptive_cards mobile mentions].freeze
        DESKTOP_CAPABILITIES = %i[rich_text adaptive_cards desktop mentions file_attachment].freeze

        attr_reader :conversation_store, :app_id

        def initialize(app_id: nil)
          super(channel_id: :teams, capabilities: CAPABILITIES)
          @app_id = app_id
          @conversation_store = Teams::ConversationStore.new
        end

        def translate_inbound(activity)
          return nil unless activity.is_a?(Hash)

          identity = Teams::BotFrameworkAuth.extract_identity(activity)
          conversation = activity['conversation'] || activity[:conversation] || {}
          text = activity['text'] || activity[:text] || ''
          text = strip_mention(text, activity)

          conversation_store.store_from_activity(activity)

          InputFrame.new(
            content: text.strip,
            channel_id: :teams,
            content_type: detect_content_type(activity),
            channel_capabilities: capabilities_for_device(activity),
            device_context: build_device_context(activity),
            auth_context: build_auth_context(identity, activity),
            metadata: {
              source_type: :human_direct,
              salience: 0.9,
              conversation_id: conversation['id'] || conversation[:id],
              activity_id: activity['id'] || activity[:id],
              activity_type: activity['type'] || activity[:type]
            }
          )
        end

        def translate_outbound(output_frame)
          content = output_frame.content.to_s
          if output_frame.content_type == :adaptive_card
            { type: 'adaptive_card', card: output_frame.content }
          else
            { type: 'text', text: content }
          end
        end

        def deliver(rendered_content, conversation_id: nil)
          ref = conversation_id && conversation_store.lookup(conversation_id)
          return { error: :no_conversation_reference } unless ref

          deliver_via_bot(rendered_content, ref)
        end

        def validate_inbound(token, allow_emulator: false)
          return { valid: false, error: :no_app_id } unless app_id

          Teams::BotFrameworkAuth.validate_token(token, app_id: app_id, allow_emulator: allow_emulator)
        end

        private

        def strip_mention(text, activity)
          bot_id = (activity['recipient'] || activity[:recipient] || {})['id']
          entities = activity['entities'] || activity[:entities] || []
          entities.select { |e| mention_for_bot?(e, bot_id) }.each do |entity|
            text = text.gsub(entity['text'] || entity[:text] || '', '')
          end
          text
        end

        def mention_for_bot?(entity, bot_id)
          return false unless (entity['type'] || entity[:type]) == 'mention'

          (entity.dig('mentioned', 'id') || entity.dig(:mentioned, :id)) == bot_id
        end

        def detect_content_type(activity)
          attachments = activity['attachments'] || activity[:attachments] || []
          return :adaptive_card if attachments.any? { |a| a['contentType']&.include?('adaptive') }
          return :file if attachments.any? { |a| a['contentType']&.include?('file') }

          :text
        end

        def capabilities_for_device(activity)
          channel_data = activity['channelData'] || activity[:channelData] || {}
          client_info = channel_data['clientInfo'] || channel_data[:clientInfo] || {}
          platform = client_info['platform'] || client_info[:platform]

          case platform&.downcase
          when 'ios', 'android' then MOBILE_CAPABILITIES
          else DESKTOP_CAPABILITIES
          end
        end

        def build_device_context(activity)
          channel_data = activity['channelData'] || activity[:channelData] || {}
          client_info = channel_data['clientInfo'] || channel_data[:clientInfo] || {}
          platform = client_info['platform'] || client_info[:platform]

          {
            platform: platform&.downcase&.to_sym || :desktop,
            input_method: :keyboard,
            locale: client_info['locale'] || client_info[:locale]
          }
        end

        def build_auth_context(identity, activity)
          {
            aad_object_id: identity[:aad_object_id],
            user_id: identity[:user_id],
            user_name: identity[:user_name],
            tenant_id: identity[:tenant_id],
            service_url: activity['serviceUrl'] || activity[:serviceUrl]
          }
        end

        def deliver_via_bot(rendered_content, ref)
          unless bot_runner_available?
            return { error: :bot_runner_not_available,
                     message: 'lex-microsoft_teams Bot runner not loaded' }
          end

          bot = Legion::Extensions::MicrosoftTeams::Client.new
          if rendered_content.is_a?(Hash) && rendered_content[:type] == 'adaptive_card'
            bot.send_card(service_url: ref.service_url, conversation_id: ref.conversation_id,
                          card: rendered_content[:card])
          else
            text = rendered_content.is_a?(Hash) ? rendered_content[:text] : rendered_content.to_s
            bot.send_text(service_url: ref.service_url, conversation_id: ref.conversation_id,
                          text: text)
          end
        end

        def bot_runner_available?
          defined?(Legion::Extensions::MicrosoftTeams::Client)
        end
      end
    end
  end
end
