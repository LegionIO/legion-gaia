# frozen_string_literal: true

require 'openssl'

module Legion
  module Gaia
    module Channels
      module Slack
        module SigningVerifier
          SLACK_VERSION = 'v0'
          MAX_TIMESTAMP_AGE = 300

          module_function

          def verify(signing_secret:, timestamp:, body:, signature:)
            return { valid: false, error: :missing_params } unless signing_secret && timestamp && body && signature
            if (Time.now.to_i - timestamp.to_i).abs > MAX_TIMESTAMP_AGE
              return { valid: false, error: :timestamp_expired }
            end

            basestring = "#{SLACK_VERSION}:#{timestamp}:#{body}"
            computed = "#{SLACK_VERSION}=#{OpenSSL::HMAC.hexdigest('SHA256', signing_secret, basestring)}"

            secure_compare(computed, signature) ? { valid: true } : { valid: false, error: :signature_mismatch }
          end

          def secure_compare(left, right)
            return false unless left.bytesize == right.bytesize

            OpenSSL.fixed_length_secure_compare(left, right)
          end
        end
      end
    end
  end
end
