# frozen_string_literal: true

module Legion
  module Gaia
    module Channels
      module Teams
        class ConversationStore
          Reference = ::Data.define(:conversation_id, :service_url, :tenant_id, :bot_id,
                                    :last_activity_id, :updated_at) do
            def initialize(conversation_id:, service_url:, tenant_id: nil, bot_id: nil,
                           last_activity_id: nil, updated_at: Time.now.utc)
              super
            end
          end

          UserProfile = ::Data.define(:user_id, :service_url, :tenant_id, :updated_at) do
            def initialize(user_id:, service_url:, tenant_id: nil, updated_at: Time.now.utc)
              super
            end
          end

          def initialize
            @references = {}
            @user_profiles = {}
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

          def store_user_profile(user_id:, service_url:, tenant_id: nil)
            return unless user_id && service_url

            @mutex.synchronize do
              @user_profiles[user_id] = UserProfile.new(
                user_id: user_id,
                service_url: service_url,
                tenant_id: tenant_id
              )
            end
          end

          def store_from_activity(activity)
            parsed = parse_activity(activity)
            store(**parsed.slice(:conversation_id, :service_url, :tenant_id, :bot_id, :activity_id))
            store_user_profile(
              user_id: parsed[:user_id],
              service_url: parsed[:service_url],
              tenant_id: parsed[:tenant_id]
            )
          end

          def lookup(conversation_id)
            @mutex.synchronize { @references[conversation_id] }
          end

          def lookup_user_profile(user_id)
            @mutex.synchronize { @user_profiles[user_id] }
          end

          def conversations_for_user(user_id)
            @mutex.synchronize do
              @references.values.select { |ref| ref.tenant_id && user_related?(ref, user_id) }
            end
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
            @mutex.synchronize do
              @references.clear
              @user_profiles.clear
            end
          end

          private

          def user_related?(ref, user_id)
            profile = @user_profiles[user_id]
            return false unless profile

            profile.tenant_id == ref.tenant_id
          end

          def parse_activity(activity)
            conversation = fetch(activity, 'conversation') || {}
            recipient = fetch(activity, 'recipient') || {}
            from = fetch(activity, 'from') || {}
            {
              conversation_id: fetch(conversation, 'id'),
              service_url: fetch(activity, 'serviceUrl'),
              tenant_id: fetch(conversation, 'tenantId'),
              bot_id: recipient['id'],
              activity_id: fetch(activity, 'id'),
              user_id: from['id']
            }
          end

          def fetch(hash, string_key)
            hash[string_key] || hash[string_key.to_sym]
          end
        end
      end
    end
  end
end
