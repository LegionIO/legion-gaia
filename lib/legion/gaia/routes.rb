# frozen_string_literal: true

# Self-registering route module for legion-gaia.
# All routes previously defined in LegionIO/lib/legion/api/gaia.rb now live here
# and are mounted via Legion::API.register_library_routes when legion-gaia boots.
#
# LegionIO/lib/legion/api/gaia.rb is preserved for backward compatibility but guards
# its registration with defined?(Legion::Gaia::Routes) so double-registration is avoided.

module Legion
  module Gaia
    module Routes
      def self.registered(app)
        app.helpers do # rubocop:disable Metrics/BlockLength
          unless method_defined?(:gaia_available?)
            define_method(:gaia_available?) do
              defined?(Legion::Gaia) && Legion::Gaia.respond_to?(:started?) && Legion::Gaia.started?
            end
          end

          unless method_defined?(:gaia_buffer_max_size)
            define_method(:gaia_buffer_max_size) do
              return nil unless defined?(Legion::Gaia::SensoryBuffer)

              Legion::Gaia::SensoryBuffer::MAX_BUFFER_SIZE
            rescue NameError => e
              Legion::Logging.debug "[gaia] route helpers failed #{e.class}: #{e.message}" if defined?(Legion::Logging)
              nil
            end
          end

          unless method_defined?(:build_channel_info)
            define_method(:build_channel_info) do |channel_id, adapter|
              info = { id: channel_id, started: adapter&.started? || false }
              info[:capabilities] = adapter.capabilities if adapter.respond_to?(:capabilities)
              info[:type] = adapter.class.name.split('::').last if adapter
              info
            end
          end

          unless method_defined?(:json_response)
            define_method(:json_response) do |data, status_code: 200|
              content_type :json
              status status_code
              Legion::JSON.dump({ data: data })
            end
          end

          unless method_defined?(:json_error)
            define_method(:json_error) do |code, message, status_code: 400|
              content_type :json
              status status_code
              Legion::JSON.dump({ error: { code: code, message: message } })
            end
          end
        end

        register_status_route(app)
        register_ticks_route(app)
        register_channels_route(app)
        register_buffer_route(app)
        register_sessions_route(app)
        register_teams_webhook_route(app)
      end

      def self.register_status_route(app)
        app.get '/api/gaia/status' do
          if gaia_available?
            json_response(Legion::Gaia.status)
          else
            json_response({ started: false }, status_code: 503)
          end
        end
      end

      def self.register_ticks_route(app)
        app.get '/api/gaia/ticks' do
          halt 503, json_error('gaia_unavailable', 'gaia is not started', status_code: 503) unless gaia_available?

          max_limit =
            if defined?(Legion::Gaia::TickHistory) && Legion::Gaia::TickHistory.const_defined?(:MAX_ENTRIES)
              Legion::Gaia::TickHistory::MAX_ENTRIES
            else
              200
            end

          limit = (params[:limit] || 50).to_i.clamp(1, max_limit)
          events = Legion::Gaia.tick_history&.recent(limit: limit) || []
          json_response({ events: events })
        end
      end

      def self.register_channels_route(app)
        app.get '/api/gaia/channels' do
          halt 503, json_error('gaia_unavailable', 'gaia is not started', status_code: 503) unless gaia_available?

          registry = Legion::Gaia.channel_registry
          return json_response({ channels: [] }) unless registry

          channels = registry.active_channels.map do |ch_id|
            adapter = registry.adapter_for(ch_id)
            build_channel_info(ch_id, adapter)
          end

          json_response({ channels: channels, count: channels.size })
        end
      end

      def self.register_buffer_route(app)
        app.get '/api/gaia/buffer' do
          halt 503, json_error('gaia_unavailable', 'gaia is not started', status_code: 503) unless gaia_available?

          buffer = Legion::Gaia.sensory_buffer
          json_response({
                          depth: buffer&.size || 0,
                          empty: buffer.nil? || buffer.empty?,
                          max_size: gaia_buffer_max_size
                        })
        end
      end

      def self.register_sessions_route(app)
        app.get '/api/gaia/sessions' do
          halt 503, json_error('gaia_unavailable', 'gaia is not started', status_code: 503) unless gaia_available?

          store = Legion::Gaia.session_store
          json_response({
                          count: store&.size || 0,
                          active: gaia_available?
                        })
        end
      end

      def self.register_teams_webhook_route(app)
        app.post '/api/channels/teams/webhook' do
          if defined?(Legion::Logging)
            Legion::Logging.debug "API: POST /api/channels/teams/webhook params=#{params.keys}"
          end
          body = request.body.read
          activity = Legion::JSON.load(body)

          adapter = Routes.teams_adapter
          unless adapter
            if defined?(Legion::Logging)
              Legion::Logging.warn 'API POST /api/channels/teams/webhook returned 503: teams adapter not available'
            end
            halt 503, json_response({ error: 'teams adapter not available' }, status_code: 503)
          end

          input_frame = adapter.translate_inbound(activity)
          unless input_frame
            if defined?(Legion::Logging)
              Legion::Logging.warn 'API POST /api/channels/teams/webhook returned 422: ' \
                                   'unsupported or malformed Teams activity'
            end
            halt 422, json_error('invalid_teams_activity', 'unsupported or malformed Teams activity',
                                 status_code: 422)
          end

          Legion::Gaia.ingest(input_frame) if defined?(Legion::Gaia)
          Legion::Logging.info "API: accepted Teams webhook frame_id=#{input_frame.id}" if defined?(Legion::Logging)
          json_response({ status: 'accepted', frame_id: input_frame.id })
        end
      end

      def self.teams_adapter
        return nil unless defined?(Legion::Gaia) && Legion::Gaia.respond_to?(:channel_registry)
        return nil unless Legion::Gaia.channel_registry

        Legion::Gaia.channel_registry.adapter_for(:teams)
      rescue StandardError => e
        Legion::Logging.warn "Gaia#teams_adapter failed: #{e.message}" if defined?(Legion::Logging)
        nil
      end

      class << self
        private :register_status_route, :register_ticks_route, :register_channels_route,
                :register_buffer_route, :register_sessions_route, :register_teams_webhook_route
      end
    end
  end
end
