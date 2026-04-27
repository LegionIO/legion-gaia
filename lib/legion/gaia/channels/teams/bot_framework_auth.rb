# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'openssl'
require 'base64'
require 'json'
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

            return { valid: false, error: :invalid_signature } unless signature_valid?(header, parts)

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
            decoded = decode_base64url(segment)
            ::JSON.parse(decoded)
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'gaia.channels.teams.bot_framework_auth.decode_jwt_segment')
            nil
          end

          def signature_valid?(header, parts)
            return false unless header['alg'] == 'RS256'

            public_key = public_key_for(header)
            return false unless public_key

            signature = decode_base64url(parts[2])
            signing_input = parts[0, 2].join('.')
            public_key.verify(OpenSSL::Digest.new('SHA256'), signature, signing_input)
          rescue StandardError => e
            handle_exception(e, level: :debug, operation: 'gaia.channels.teams.bot_framework_auth.signature_valid')
            false
          end

          def public_key_for(header)
            kid = header['kid']
            return nil if kid.to_s.empty?

            key = jwks_keys.find { |candidate| candidate['kid'] == kid }
            return nil unless key

            certificate = Array(key['x5c']).first
            return nil unless certificate

            OpenSSL::X509::Certificate.new(Base64.decode64(certificate)).public_key
          end

          def jwks_keys
            now = Time.now.to_i
            cache = @jwks_cache
            return cache[:keys] if cache && cache[:expires_at] > now

            metadata = fetch_json(OPENID_METADATA_URL)
            jwks_uri = metadata['jwks_uri']
            keys = fetch_json(jwks_uri).fetch('keys', [])
            @jwks_cache = { keys: keys, expires_at: now + JWKS_CACHE_TTL }
            keys
          end

          def fetch_json(url)
            uri = URI(url)
            response = Net::HTTP.get_response(uri)
            raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

            ::JSON.parse(response.body)
          end

          def decode_base64url(segment)
            remainder = segment.length % 4
            padded = remainder.zero? ? segment : segment + ('=' * (4 - remainder))
            Base64.urlsafe_decode64(padded)
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
