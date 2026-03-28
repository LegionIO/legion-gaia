# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Routes do
  it 'is a module' do
    expect(Legion::Gaia::Routes).to be_a(Module)
  end

  it 'responds to registered' do
    expect(Legion::Gaia::Routes).to respond_to(:registered)
  end
end
