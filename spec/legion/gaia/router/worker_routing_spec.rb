# frozen_string_literal: true

RSpec.describe Legion::Gaia::Router::WorkerRouting do
  subject(:routing) { described_class.new }

  describe '#register and #resolve' do
    it 'registers and resolves a worker route' do
      routing.register(identity: 'oid-1', worker_id: 'worker-a')
      route = routing.resolve('oid-1')
      expect(route[:worker_id]).to eq('worker-a')
      expect(route[:registered_at]).to be_a(Time)
    end

    it 'resolves worker_id directly' do
      routing.register(identity: 'oid-1', worker_id: 'worker-a')
      expect(routing.resolve_worker_id('oid-1')).to eq('worker-a')
    end

    it 'returns nil for unknown identity' do
      expect(routing.resolve('unknown')).to be_nil
      expect(routing.resolve_worker_id('unknown')).to be_nil
    end

    it 'overwrites existing route on re-register' do
      routing.register(identity: 'oid-1', worker_id: 'old')
      routing.register(identity: 'oid-1', worker_id: 'new')
      expect(routing.resolve_worker_id('oid-1')).to eq('new')
    end
  end

  describe '#unregister' do
    it 'removes a route' do
      routing.register(identity: 'oid-1', worker_id: 'worker-a')
      routing.unregister('oid-1')
      expect(routing.resolve('oid-1')).to be_nil
    end
  end

  describe '#registered_identities' do
    it 'returns all registered identities' do
      routing.register(identity: 'a', worker_id: 'w1')
      routing.register(identity: 'b', worker_id: 'w2')
      expect(routing.registered_identities).to contain_exactly('a', 'b')
    end
  end

  describe '#size and #clear' do
    it 'tracks count and clears' do
      routing.register(identity: 'a', worker_id: 'w1')
      expect(routing.size).to eq(1)
      routing.clear
      expect(routing.size).to eq(0)
    end
  end

  describe '#worker_allowed?' do
    it 'allows all workers when allowlist is empty' do
      expect(routing.worker_allowed?('any-worker')).to be true
    end

    context 'with allowlist' do
      subject(:routing) { described_class.new(allowed_worker_ids: %w[w1 w2]) }

      it 'allows listed workers' do
        expect(routing.worker_allowed?('w1')).to be true
      end

      it 'rejects unlisted workers' do
        expect(routing.worker_allowed?('w3')).to be false
      end

      it 'rejects registration of unlisted workers' do
        result = routing.register(identity: 'oid-1', worker_id: 'w3')
        expect(result[:registered]).to be false
        expect(result[:reason]).to eq(:not_allowed)
      end
    end
  end

  describe '#resolve_from_db' do
    let(:digital_worker_model) { class_double('DigitalWorker') }
    let(:worker) { instance_double('DigitalWorkerRow', active?: true, worker_id: 'w3') }

    before do
      stub_const('Legion::Data::Model::DigitalWorker', digital_worker_model)
      allow(digital_worker_model).to receive(:first).with(entra_oid: 'oid-1').and_return(worker)
    end

    it 'returns nil when DB-backed worker resolution finds a disallowed worker' do
      routing = described_class.new(allowed_worker_ids: %w[w1 w2])

      expect(routing.resolve_from_db('oid-1')).to be_nil
      expect(routing.resolve_worker_id('oid-1')).to be_nil
    end
  end
end
