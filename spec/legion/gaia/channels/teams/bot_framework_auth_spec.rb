# frozen_string_literal: true

require 'json'

RSpec.describe Legion::Gaia::Channels::Teams::BotFrameworkAuth do
  let(:app_id) { 'test-app-id-12345' }
  let(:now) { Time.now.to_i }
  let(:rsa_key) { OpenSSL::PKey::RSA.generate(2048) }

  def build_jwt(header_hash, payload_hash, key: nil)
    h = Base64.urlsafe_encode64(JSON.dump(header_hash), padding: false)
    p = Base64.urlsafe_encode64(JSON.dump(payload_hash), padding: false)
    signature = if key
                  key.sign(OpenSSL::Digest.new('SHA256'), "#{h}.#{p}")
                else
                  'fake-signature'
                end
    s = Base64.urlsafe_encode64(signature, padding: false)
    "#{h}.#{p}.#{s}"
  end

  describe '.validate_token' do
    it 'returns missing_token for nil' do
      result = described_class.validate_token(nil, app_id: app_id)
      expect(result).to eq({ valid: false, error: :missing_token })
    end

    it 'returns missing_token for empty string' do
      result = described_class.validate_token('', app_id: app_id)
      expect(result).to eq({ valid: false, error: :missing_token })
    end

    it 'returns malformed_jwt for non-JWT string' do
      result = described_class.validate_token('not-a-jwt', app_id: app_id)
      expect(result).to eq({ valid: false, error: :malformed_jwt })
    end

    it 'returns decode_failed for invalid base64' do
      result = described_class.validate_token('!!!.@@@.###', app_id: app_id)
      expect(result).to eq({ valid: false, error: :decode_failed })
    end

    context 'with valid JWT structure' do
      let(:header) { { alg: 'RS256', typ: 'JWT', kid: 'key-1' } }
      let(:valid_payload) do
        {
          'iss' => 'https://api.botframework.com',
          'aud' => app_id,
          'exp' => now + 3600,
          'nbf' => now - 60,
          'oid' => 'user-oid-123',
          'appid' => 'bot-app-id',
          'tid' => 'tenant-123'
        }
      end

      before do
        allow(described_class).to receive(:public_key_for).and_return(rsa_key.public_key)
      end

      it 'returns valid with correct claims' do
        token = build_jwt(header, valid_payload, key: rsa_key)
        result = described_class.validate_token(token, app_id: app_id)
        expect(result[:valid]).to be true
        expect(result[:entra_oid]).to eq('user-oid-123')
        expect(result[:app_id]).to eq('bot-app-id')
        expect(result[:tenant_id]).to eq('tenant-123')
      end

      it 'returns azp when appid is absent' do
        payload = valid_payload.merge('appid' => nil, 'azp' => 'azp-id')
        token = build_jwt(header, payload, key: rsa_key)
        result = described_class.validate_token(token, app_id: app_id)
        expect(result[:app_id]).to eq('azp-id')
      end

      it 'rejects forged signatures' do
        token = build_jwt(header, valid_payload)
        result = described_class.validate_token(token, app_id: app_id)
        expect(result).to eq({ valid: false, error: :invalid_signature })
      end

      it 'rejects expired tokens' do
        payload = valid_payload.merge('exp' => now - 10)
        token = build_jwt(header, payload)
        result = described_class.validate_token(token, app_id: app_id)
        expect(result).to eq({ valid: false, error: :token_expired })
      end

      it 'rejects tokens not yet valid (nbf too far in future)' do
        payload = valid_payload.merge('nbf' => now + 600)
        token = build_jwt(header, payload)
        result = described_class.validate_token(token, app_id: app_id)
        expect(result).to eq({ valid: false, error: :token_not_yet_valid })
      end

      it 'rejects invalid issuer' do
        payload = valid_payload.merge('iss' => 'https://evil.example.com')
        token = build_jwt(header, payload)
        result = described_class.validate_token(token, app_id: app_id)
        expect(result[:error]).to eq(:invalid_issuer)
      end

      it 'rejects wrong audience' do
        payload = valid_payload.merge('aud' => 'wrong-app-id')
        token = build_jwt(header, payload)
        result = described_class.validate_token(token, app_id: app_id)
        expect(result[:error]).to eq(:invalid_audience)
      end

      it 'accepts emulator issuer when allowed' do
        payload = valid_payload.merge('iss' => 'https://sts.windows.net/d6d49420-f39b-4df7-a1dc-d59a935871db/')
        token = build_jwt(header, payload, key: rsa_key)
        result = described_class.validate_token(token, app_id: app_id, allow_emulator: true)
        expect(result[:valid]).to be true
      end

      it 'rejects emulator issuer when not allowed' do
        payload = valid_payload.merge('iss' => 'https://sts.windows.net/d6d49420-f39b-4df7-a1dc-d59a935871db/')
        token = build_jwt(header, payload)
        result = described_class.validate_token(token, app_id: app_id, allow_emulator: false)
        expect(result[:error]).to eq(:invalid_issuer)
      end
    end
  end

  describe '.extract_identity' do
    it 'extracts identity from string-keyed activity' do
      activity = {
        'from' => { 'aadObjectId' => 'oid-1', 'id' => 'user-1', 'name' => 'Alice' },
        'channelData' => { 'tenant' => { 'id' => 'tenant-1' } }
      }
      identity = described_class.extract_identity(activity)
      expect(identity[:aad_object_id]).to eq('oid-1')
      expect(identity[:user_id]).to eq('user-1')
      expect(identity[:user_name]).to eq('Alice')
      expect(identity[:tenant_id]).to eq('tenant-1')
    end

    it 'extracts identity from symbol-keyed activity' do
      activity = {
        from: { aadObjectId: 'oid-2', id: 'user-2', name: 'Bob' },
        channelData: { tenant: { id: 'tenant-2' } }
      }
      identity = described_class.extract_identity(activity)
      expect(identity[:aad_object_id]).to eq('oid-2')
      expect(identity[:user_id]).to eq('user-2')
      expect(identity[:tenant_id]).to eq('tenant-2')
    end

    it 'handles missing from gracefully' do
      identity = described_class.extract_identity({})
      expect(identity[:aad_object_id]).to be_nil
      expect(identity[:user_id]).to be_nil
    end
  end

  describe '.decode_jwt_segment' do
    it 'decodes a valid base64url JSON segment' do
      data = { 'key' => 'value' }
      segment = Base64.urlsafe_encode64(JSON.dump(data), padding: false)
      result = described_class.decode_jwt_segment(segment)
      expect(result).to eq(data)
    end

    it 'returns nil for invalid segment' do
      expect(described_class.decode_jwt_segment('!!invalid!!')).to be_nil
    end
  end
end
