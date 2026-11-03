# frozen_string_literal: true

RSpec.describe Legion::Gaia::TickHistory do
  subject(:history) { described_class.new }

  it 'exposes scheduled, unavailable and budget-skipped work without inventing successful events' do
    history.record({ phases_scheduled: %i[memory_retrieval prediction_engine global_workspace metacognition],
                     phases_skipped: [:metacognition],
                     results: { memory_retrieval: { success: false, error: :store_failed }, prediction_engine: {} } },
                   identity: 'alice', conversation_id: 'c1', exchange_id: 'e1')
    events = history.recent.to_h { |entry| [entry[:phase], entry] }
    expect(events['memory_retrieval']).to include(status: :failed, meaningful: false)
    expect(events['prediction_engine']).to include(status: :skipped, meaningful: false)
    expect(events['global_workspace']).to include(status: :unavailable, reason: :missing_phase_result)
    expect(events['metacognition']).to include(status: :budget_skipped, reason: :tick_budget_exhausted)
  end

  it 'preserves multi-provider failures instead of dropping array-shaped phase results' do
    history.record({ results: { partner_reflection: [{ partner_bond: { stage: :established } },
                                                     { success: false, error: :storage_unavailable }] } })
    event = history.recent.first
    expect(event).to include(status: :failed, meaningful: false)
    expect(event[:handlers].map { |handler| handler[:status] }).to eq(%i[completed failed])
  end

  it 'filters interleaved human/conversation events without including another owner' do
    history.record({ results: { sensory_processing: { filtered: [{ value: 'one' }], elapsed_ms: 1.5 } } },
                   identity: 'alice', conversation_id: 'a1')
    history.record({ results: { sensory_processing: { filtered: [{ value: 'two' }] } } }, identity: 'bob',
                                                                                          conversation_id: 'b1')
    history.record({ results: { memory_retrieval: { traces: [], status: :skipped } } }, identity: 'alice',
                                                                                        conversation_id: 'a2')
    events = history.recent(identity: 'alice', conversation_id: 'a1')
    expect(events.map { |entry| entry[:phase] }).to eq(['sensory_processing'])
    expect(events.first).to include(identity: 'alice', conversation_id: 'a1', duration_ms: 1.5)
  end

  it 'does not let callers mutate the retained event or its nested handler statuses' do
    history.record({ results: { phase: [{ useful: true }, { status: :unavailable }] } })
    snapshot = history.recent.first
    snapshot[:status] = :completed
    expect { snapshot[:handlers].first[:status] = :completed }.to raise_error(FrozenError)
    expect(history.recent.first[:status]).to eq(:partial)
  end

  it 'keeps the newest bounded history in insertion order' do
    (described_class::MAX_ENTRIES + 5).times do |index|
      history.record({ results: { phase: { useful: true, elapsed_ms: index } } })
    end
    expect(history.size).to eq(described_class::MAX_ENTRIES)
    expect(history.recent(limit: 3).map { |entry| entry[:duration_ms] })
      .to eq([described_class::MAX_ENTRIES + 2, described_class::MAX_ENTRIES + 3, described_class::MAX_ENTRIES + 4])
  end

  it 'keeps every event from concurrent writers' do
    writers = 5.times.map do |index|
      Thread.new do
        10.times { history.record({ results: { phase: { useful: true } } }, identity: "human-#{index}") }
      end
    end
    writers.each(&:join)
    expect(history.size).to eq(50)
    5.times { |index| expect(history.recent(identity: "human-#{index}").size).to eq(10) }
  end
end
