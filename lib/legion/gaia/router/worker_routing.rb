# frozen_string_literal: true

module Legion
  module Gaia
    module Router
      class WorkerRouting
        include Legion::Logging::Helper

        attr_reader :allowed_worker_ids

        def initialize(allowed_worker_ids: [])
          log.unknown "initialize(allowed_worker_ids: #{allowed_worker_ids})"
          @routes = {}
          @allowed_worker_ids = allowed_worker_ids
          @mutex = Mutex.new
        end

        def register(identity:, worker_id:)
          return { registered: false, reason: :not_allowed } unless worker_allowed?(worker_id)

          @mutex.synchronize do
            @routes[identity] = { worker_id: worker_id, registered_at: Time.now.utc }
          end
          { registered: true, identity: identity, worker_id: worker_id }
        end

        def resolve(identity)
          @mutex.synchronize { @routes[identity] }
        end

        def resolve_worker_id(identity)
          route = resolve(identity)
          route&.fetch(:worker_id, nil)
        end

        def unregister(identity)
          @mutex.synchronize { @routes.delete(identity) }
        end

        def registered_identities
          @mutex.synchronize { @routes.keys }
        end

        def size
          @mutex.synchronize { @routes.size }
        end

        def clear
          @mutex.synchronize { @routes.clear }
        end

        def worker_allowed?(worker_id)
          return true if allowed_worker_ids.empty?

          allowed_worker_ids.include?(worker_id)
        end

        def resolve_from_db(identity)
          return nil unless defined?(Legion::Data::Model::DigitalWorker)

          worker = Legion::Data::Model::DigitalWorker.first(entra_oid: identity)
          return nil unless worker&.active?

          register(identity: identity, worker_id: worker.worker_id)
          worker.worker_id
        end
      end
    end
  end
end
