# frozen_string_literal: true

RSpec.describe Legion::Gaia::Workflow do
  describe 'error hierarchy' do
    it 'all errors inherit from Workflow::Error' do
      expect(Legion::Gaia::Workflow::InvalidTransition.superclass).to eq(described_class::Error)
      expect(Legion::Gaia::Workflow::GuardRejected.superclass).to eq(described_class::Error)
      expect(Legion::Gaia::Workflow::CheckpointBlocked.superclass).to eq(described_class::Error)
      expect(Legion::Gaia::Workflow::UnknownState.superclass).to eq(described_class::Error)
      expect(Legion::Gaia::Workflow::NotInitialized.superclass).to eq(described_class::Error)
    end

    it 'Workflow::Error inherits from StandardError' do
      expect(described_class::Error.superclass).to eq(StandardError)
    end
  end

  describe 'InvalidTransition' do
    subject(:err) { described_class::InvalidTransition.new(:pending, :done) }

    it 'stores from and to' do
      expect(err.from).to eq(:pending)
      expect(err.to).to eq(:done)
    end

    it 'includes state names in message' do
      expect(err.message).to include('pending')
      expect(err.message).to include('done')
    end
  end

  describe 'GuardRejected' do
    subject(:err) { described_class::GuardRejected.new(:running, :done, :quality) }

    it 'stores from, to, and guard_name' do
      expect(err.from).to eq(:running)
      expect(err.to).to eq(:done)
      expect(err.guard_name).to eq(:quality)
    end

    it 'includes guard name in message' do
      expect(err.message).to include('quality')
    end

    it 'omits guard label when guard_name is nil' do
      err2 = described_class::GuardRejected.new(:a, :b)
      expect(err2.message).not_to include('guard:')
    end
  end

  describe 'CheckpointBlocked' do
    subject(:err) { described_class::CheckpointBlocked.new(:enriching, :quality_check) }

    it 'stores state and checkpoint_name' do
      expect(err.state).to eq(:enriching)
      expect(err.checkpoint_name).to eq(:quality_check)
    end

    it 'includes both names in message' do
      expect(err.message).to include('enriching')
      expect(err.message).to include('quality_check')
    end
  end

  describe 'UnknownState' do
    it 'includes the bad state name in the message' do
      err = described_class::UnknownState.new(:ghost)
      expect(err.message).to include('ghost')
    end
  end

  describe 'NotInitialized' do
    it 'has a descriptive message' do
      err = described_class::NotInitialized.new
      expect(err.message).not_to be_empty
    end
  end
end
