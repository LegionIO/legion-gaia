# frozen_string_literal: true

module Legion
  module Gaia
    module Channels
      module Teams
        class ConversationStore
          Reference = Data.define(:conversation_id, :service_url, :tenant_id, :bot_id,
                                  :last_activity_id, :updated_at) do
            def initialize(conversation_id:, service_url:, tenant_id: nil, bot_id: nil,
                           last_activity_id: nil, updated_at: Time.now.utc)
              super
            end
          end

          def initialize
            @references = {}
            @mutex = Mutex.new
          end

          def store(conversation_id:, service_url:, tenant_id: nil, bot_id: nil, activity_id: nil)
            @mutex.synchronize do
              @references[conversation_id] = Reference.new(
                conversation_id: conversation_id,
                service_url: service_url,
                tenant_id: tenant_id,
                bot_id: bot_id,
                last_activity_id: activity_id
              )
            end
          end

          def store_from_activity(activity)
            conversation = activity['conversation'] || activity[:conversation] || {}
            store(
              conversation_id: conversation['id'] || conversation[:id],
              service_url: activity['serviceUrl'] || activity[:serviceUrl],
              tenant_id: conversation['tenantId'] || conversation[:tenantId],
              bot_id: (activity['recipient'] || activity[:recipient] || {})['id'],
              activity_id: activity['id'] || activity[:id]
            )
          end

          def lookup(conversation_id)
            @mutex.synchronize { @references[conversation_id] }
          end

          def remove(conversation_id)
            @mutex.synchronize { @references.delete(conversation_id) }
          end

          def conversations
            @mutex.synchronize { @references.keys }
          end

          def size
            @mutex.synchronize { @references.size }
          end

          def clear
            @mutex.synchronize { @references.clear }
          end
        end
      end
    end
  end
end
