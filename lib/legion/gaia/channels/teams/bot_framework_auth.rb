# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'openssl'
require 'base64'
require 'legion/logging/helper'

module Legion
  module Gaia
    module Channels
      module Teams
        module BotFrameworkAuth
          extend Legion::Logging::Helper

          OPENID_METADATA_URL = 'https://login.botframework.com/v1/.well-known/openidconfiguration'
          BOT_FRAMEWORK_ISSUER = 'https://api.botframework.com'
          EMULATOR_ISSUER = 'https://sts.windows.net/d6d49420-f39b-4df7-a1dc-d59a935871db/'
          JWKS_CACHE_TTL = 3600

          module_function

          def validate_token(token, app_id:, allow_emulator: false)
            return { valid: false, error: :missing_token } if token.nil? || token.empty?

            parts = token.split('.')
            return { valid: false, error: :malformed_jwt } unless parts.size == 3

            header = decode_jwt_segment(parts[0])
            payload = decode_jwt_segment(parts[1])

            return { valid: false, error: :decode_failed } unless header && payload

            validation = validate_claims(payload, app_id: app_id, allow_emulator: allow_emulator)
            return validation unless validation[:valid]

            {
              valid: true,
              claims: payload,
              entra_oid: payload['oid'],
              app_id: payload['appid'] || payload['azp'],
              tenant_id: payload['tid'],
              service_url: payload['serviceurl']
            }
          end

          def validate_claims(payload, app_id:, allow_emulator: false)
            return check_expiry(payload) unless token_time_valid?(payload)
            return check_issuer(payload, allow_emulator) unless issuer_valid?(payload, allow_emulator)
            return { valid: false, error: :invalid_audience, audience: payload['aud'] } unless payload['aud'] == app_id

            { valid: true }
          end

          def extract_identity(activity)
            from = activity['from'] || activity[:from] || {}
            {
              aad_object_id: from['aadObjectId'] || from[:aadObjectId],
              user_id: from['id'] || from[:id],
              user_name: from['name'] || from[:name],
              tenant_id: activity.dig('channelData', 'tenant', 'id') ||
                activity.dig(:channelData, :tenant, :id)
            }
          end

          def decode_jwt_segment(segment)
            remainder = segment.length % 4
            padded = remainder.zero? ? segment : segment + ('=' * (4 - remainder))
            decoded = Base64.urlsafe_decode64(padded)
            ::JSON.parse(decoded)
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'gaia.channels.teams.bot_framework_auth.decode_jwt_segment')
            nil
          end

          def token_time_valid?(payload)
            now = Time.now.to_i
            return false if payload['exp'] && payload['exp'].to_i < now
            return false if payload['nbf'] && payload['nbf'].to_i > now + 300

            true
          end

          def check_expiry(payload)
            now = Time.now.to_i
            return { valid: false, error: :token_expired } if payload['exp'] && payload['exp'].to_i < now

            { valid: false, error: :token_not_yet_valid }
          end

          def issuer_valid?(payload, allow_emulator)
            issuer = payload['iss']
            valid_issuers = [BOT_FRAMEWORK_ISSUER]
            valid_issuers << EMULATOR_ISSUER if allow_emulator
            valid_issuers.any? { |i| issuer&.start_with?(i) || issuer == i }
          end

          def check_issuer(payload, _allow_emulator)
            { valid: false, error: :invalid_issuer, issuer: payload['iss'] }
          end
        end
      end
    end
  end
end
