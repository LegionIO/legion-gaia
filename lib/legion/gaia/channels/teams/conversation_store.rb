# frozen_string_literal: true

module Legion
  module Gaia
    module Channels
      module Teams
        class ConversationStore
          Reference = ::Data.define(:conversation_id, :service_url, :tenant_id, :bot_id,
                                    :last_activity_id, :updated_at, :user_id, :conversation_type) do
            def initialize(conversation_id:, service_url:, tenant_id: nil, bot_id: nil, user_id: nil,
                           conversation_type: nil, last_activity_id: nil, updated_at: Time.now.utc)
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

          def store(conversation_id:, service_url:, tenant_id: nil, bot_id: nil, activity_id: nil,
                    user_id: nil, conversation_type: nil)
            @mutex.synchronize do
              @references[[tenant_id, conversation_id]] = Reference.new(
                conversation_id: conversation_id,
                service_url: service_url,
                tenant_id: tenant_id,
                bot_id: bot_id,
                user_id: user_id,
                conversation_type: conversation_type,
                last_activity_id: activity_id
              )
            end
          end

          def store_user_profile(user_id:, service_url:, tenant_id: nil)
            return unless user_id && service_url

            @mutex.synchronize do
              @user_profiles[[tenant_id, user_id]] = UserProfile.new(
                user_id: user_id,
                service_url: service_url,
                tenant_id: tenant_id
              )
            end
          end

          def store_from_activity(activity)
            parsed = parse_activity(activity)
            store(**parsed)
            store_user_profile(
              user_id: parsed[:user_id],
              service_url: parsed[:service_url],
              tenant_id: parsed[:tenant_id]
            )
          end

          def lookup(conversation_id, tenant_id: nil)
            @mutex.synchronize do
              return @references[[tenant_id, conversation_id]] if tenant_id

              matches = @references.values.select { |ref| ref.conversation_id == conversation_id }
              matches.first if matches.one?
            end
          end

          def lookup_user_profile(user_id, tenant_id: nil)
            @mutex.synchronize do
              return @user_profiles[[tenant_id, user_id]] if tenant_id

              matches = @user_profiles.values.select { |profile| profile.user_id == user_id }
              matches.first if matches.one?
            end
          end

          def conversations_for_user(user_id, tenant_id: nil)
            return [] if user_id.to_s.empty?

            @mutex.synchronize do
              matches = @references.values.select do |ref|
                ref.user_id == user_id && ref.conversation_type == 'personal' && !ref.tenant_id.to_s.empty? &&
                  (!tenant_id || ref.tenant_id == tenant_id)
              end
              return [] if !tenant_id && matches.map(&:tenant_id).uniq.size > 1

              matches.sort_by(&:updated_at).reverse
            end
          end

          def remove(conversation_id, tenant_id: nil)
            reference = lookup(conversation_id, tenant_id: tenant_id)
            return nil unless reference

            @mutex.synchronize { @references.delete([reference.tenant_id, conversation_id]) }
          end

          def conversations
            @mutex.synchronize { @references.values.map(&:conversation_id) }
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

          def parse_activity(activity)
            conversation = fetch(activity, 'conversation') || {}
            recipient = fetch(activity, 'recipient') || {}
            from = fetch(activity, 'from') || {}
            {
              conversation_id: fetch(conversation, 'id'),
              service_url: fetch(activity, 'serviceUrl'),
              tenant_id: fetch(conversation,
                               'tenantId') || fetch(fetch(fetch(activity, 'channelData') || {}, 'tenant') || {}, 'id'),
              bot_id: fetch(recipient, 'id'),
              activity_id: fetch(activity, 'id'),
              user_id: fetch(from, 'id'),
              conversation_type: fetch(conversation, 'conversationType')
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
