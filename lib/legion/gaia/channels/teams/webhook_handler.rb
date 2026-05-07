# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module Channels
      module Teams
        class WebhookHandler
          include Legion::Logging::Helper

          attr_reader :adapter

          def initialize(adapter)
            @adapter = adapter
          end

          def handle(request_body:, auth_header: nil)
            activity = parse_activity(request_body)
            return error_response(:invalid_payload, 'Could not parse activity') unless activity

            if adapter.app_id
              return error_response(:missing_auth, 'Authorization header is required') if auth_header.to_s.empty?

              token = extract_bearer_token(auth_header)
              validation = adapter.validate_inbound(token)
              return error_response(:auth_failed, validation[:error]) unless validation[:valid]
            end

            activity_type = activity['type'] || activity[:type]
            log.info("WebhookHandler received activity_type=#{activity_type}")
            case activity_type
            when 'message' then handle_message(activity)
            when 'conversationUpdate' then handle_conversation_update(activity)
            when 'invoke' then handle_invoke(activity)
            else handle_other(activity)
            end
          end

          private

          def handle_message(activity)
            frame = adapter.translate_inbound(activity)
            return error_response(:translate_failed, 'Could not translate activity') unless frame

            Legion::Gaia.ingest(frame) if Legion::Gaia.respond_to?(:ingest)
            log.info("WebhookHandler ingested frame_id=#{frame.id}")
            success_response(:message_ingested, frame.id)
          end

          def handle_conversation_update(activity)
            adapter.conversation_store.store_from_activity(activity)
            members_added = activity['membersAdded'] || activity[:membersAdded] || []
            members_removed = activity['membersRemoved'] || activity[:membersRemoved] || []

            {
              status: 200,
              type: :conversation_update,
              members_added: members_added.size,
              members_removed: members_removed.size
            }
          end

          def handle_invoke(activity)
            adapter.conversation_store.store_from_activity(activity)
            { status: 200, type: :invoke, activity_type: activity['name'] || activity[:name] }
          end

          def handle_other(activity)
            adapter.conversation_store.store_from_activity(activity)
            { status: 200, type: :ignored, activity_type: activity['type'] || activity[:type] }
          end

          def parse_activity(body)
            return body if body.is_a?(Hash)

            ::JSON.parse(body)
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'gaia.channels.teams.webhook_handler.parse_activity')
            nil
          end

          def extract_bearer_token(header)
            return nil unless header.is_a?(String)

            header.sub(/\ABearer\s+/i, '')
          end

          def success_response(type, frame_id)
            { status: 200, type: type, frame_id: frame_id }
          end

          def error_response(type, detail)
            status = %i[missing_auth auth_failed].include?(type) ? 401 : 400
            { status: status, type: type, detail: detail }
          end
        end
      end
    end
  end
end
