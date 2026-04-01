# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Routes do
  it 'is a module' do
    expect(Legion::Gaia::Routes).to be_a(Module)
  end

  it 'responds to registered' do
    expect(Legion::Gaia::Routes).to respond_to(:registered)
  end

  it 'has a register_ticks_route private class method' do
    expect(described_class.private_methods).to include(:register_ticks_route)
  end

  describe '.register_ticks_route' do
    let(:app) { double('SinatraApp') }

    it 'registers GET /api/gaia/ticks on the app' do
      expect(app).to receive(:get).with('/api/gaia/ticks')
      described_class.send(:register_ticks_route, app)
    end
  end
end
