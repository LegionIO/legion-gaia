# frozen_string_literal: true

require 'openssl'

RSpec.describe Legion::Gaia::Channels::Slack::SigningVerifier do
  let(:signing_secret) { 'test-signing-secret-12345' }
  let(:timestamp) { Time.now.to_i.to_s }
  let(:body) { '{"type":"event_callback","event":{"type":"message","text":"hello"}}' }

  def compute_signature(secret, time_stamp, raw_body)
    basestring = "v0:#{time_stamp}:#{raw_body}"
    "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, basestring)}"
  end

  describe '.verify' do
    it 'returns valid for correct signature' do
      sig = compute_signature(signing_secret, timestamp, body)
      result = described_class.verify(
        signing_secret: signing_secret,
        timestamp: timestamp,
        body: body,
        signature: sig
      )
      expect(result[:valid]).to be true
    end

    it 'returns signature_mismatch for wrong signature' do
      result = described_class.verify(
        signing_secret: signing_secret,
        timestamp: timestamp,
        body: body,
        signature: 'v0=0000000000000000000000000000000000000000000000000000000000000000'
      )
      expect(result[:error]).to eq(:signature_mismatch)
    end

    it 'returns timestamp_expired for old timestamp' do
      old_ts = (Time.now.to_i - 600).to_s
      sig = compute_signature(signing_secret, old_ts, body)
      result = described_class.verify(
        signing_secret: signing_secret,
        timestamp: old_ts,
        body: body,
        signature: sig
      )
      expect(result[:error]).to eq(:timestamp_expired)
    end

    it 'returns missing_params when parameters are nil' do
      result = described_class.verify(signing_secret: nil, timestamp: nil, body: nil, signature: nil)
      expect(result[:error]).to eq(:missing_params)
    end

    it 'rejects signature computed with wrong secret' do
      wrong_sig = compute_signature('wrong-secret', timestamp, body)
      result = described_class.verify(
        signing_secret: signing_secret,
        timestamp: timestamp,
        body: body,
        signature: wrong_sig
      )
      expect(result[:error]).to eq(:signature_mismatch)
    end
  end
end
