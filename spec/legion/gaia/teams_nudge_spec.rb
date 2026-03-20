# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'GAIA Teams auth nudge' do
  before do
    Legion::Gaia.instance_variable_set(:@teams_nudge_sent, nil)
  end

  describe '.check_teams_auth' do
    it 'sends a nudge when teams is enabled but not authenticated' do
      allow(Legion::Gaia).to receive(:teams_channel_enabled?).and_return(true)
      allow(Legion::Gaia).to receive(:teams_authenticated?).and_return(false)

      expect(Legion::Gaia::Proactive).to receive(:send_message).with(hash_including(channel_id: :cli))
      Legion::Gaia.send(:check_teams_auth)
    end

    it 'does not send a nudge when already authenticated' do
      allow(Legion::Gaia).to receive(:teams_channel_enabled?).and_return(true)
      allow(Legion::Gaia).to receive(:teams_authenticated?).and_return(true)

      expect(Legion::Gaia::Proactive).not_to receive(:send_message)
      Legion::Gaia.send(:check_teams_auth)
    end

    it 'does not send a nudge when teams channel is not enabled' do
      allow(Legion::Gaia).to receive(:teams_channel_enabled?).and_return(false)

      expect(Legion::Gaia::Proactive).not_to receive(:send_message)
      Legion::Gaia.send(:check_teams_auth)
    end

    it 'only sends once per boot' do
      allow(Legion::Gaia).to receive(:teams_channel_enabled?).and_return(true)
      allow(Legion::Gaia).to receive(:teams_authenticated?).and_return(false)
      allow(Legion::Gaia::Proactive).to receive(:send_message)

      Legion::Gaia.send(:check_teams_auth)
      expect(Legion::Gaia.send(:teams_nudge_sent?)).to be true

      expect(Legion::Gaia::Proactive).to have_received(:send_message).once
      Legion::Gaia.send(:check_teams_auth)
      expect(Legion::Gaia::Proactive).to have_received(:send_message).once
    end
  end

  describe '.teams_channel_enabled?' do
    it 'returns false when settings are nil' do
      allow(Legion::Gaia).to receive(:settings).and_return(nil)
      expect(Legion::Gaia.send(:teams_channel_enabled?)).to be false
    end

    it 'returns true when teams channel is enabled' do
      allow(Legion::Gaia).to receive(:settings).and_return({ channels: { teams: { enabled: true } } })
      expect(Legion::Gaia.send(:teams_channel_enabled?)).to be true
    end
  end

  describe '.teams_authenticated?' do
    it 'returns false when TokenCache is not defined' do
      expect(Legion::Gaia.send(:teams_authenticated?)).to be false
    end
  end
end
