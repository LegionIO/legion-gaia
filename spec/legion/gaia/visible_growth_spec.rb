# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::VisibleGrowth do
  let(:identity) { 'partner-bob' }
  let(:domain)   { 'brevity' }

  before do
    described_class.reset!
    Legion::Gaia::BehavioralSynapse.reset!
    Legion::Gaia::BondRegistry.reset!
  end

  after do
    described_class.reset!
    Legion::Gaia::BehavioralSynapse.reset!
    Legion::Gaia::BondRegistry.reset!
  end

  # --- milestone_acknowledgment ---

  describe '.milestone_acknowledgment' do
    subject(:msg) do
      described_class.milestone_acknowledgment(
        identity: identity, domain: domain, new_mode: :filter, old_mode: :observe
      )
    end

    it 'returns a non-empty string on first call' do
      expect(msg).to be_a(String)
      expect(msg).not_to be_empty
    end

    it 'mentions the domain in natural language' do
      expect(msg).to include('shorter answers')
    end

    it 'returns nil on the same transition a second time' do
      described_class.milestone_acknowledgment(
        identity: identity, domain: domain, new_mode: :filter, old_mode: :observe
      )
      expect(msg).to be_nil
    end

    it 'fires again for a different domain' do
      described_class.milestone_acknowledgment(
        identity: identity, domain: domain, new_mode: :filter, old_mode: :observe
      )
      msg2 = described_class.milestone_acknowledgment(
        identity: identity, domain: 'tone', new_mode: :filter, old_mode: :observe
      )
      expect(msg2).not_to be_nil
    end

    it 'fires again for a different tier on the same domain' do
      described_class.milestone_acknowledgment(
        identity: identity, domain: domain, new_mode: :filter, old_mode: :observe
      )
      msg2 = described_class.milestone_acknowledgment(
        identity: identity, domain: domain, new_mode: :transform, old_mode: :filter
      )
      expect(msg2).not_to be_nil
    end

    it 'fires for different identities independently' do
      described_class.milestone_acknowledgment(
        identity: identity, domain: domain, new_mode: :filter, old_mode: :observe
      )
      msg2 = described_class.milestone_acknowledgment(
        identity: 'other-person', domain: domain, new_mode: :filter, old_mode: :observe
      )
      expect(msg2).not_to be_nil
    end
  end

  # --- pain_revert_acknowledgment ---

  describe '.pain_revert_acknowledgment' do
    subject(:msg) { described_class.pain_revert_acknowledgment(identity: identity, domain: domain) }

    it 'returns a non-empty string' do
      expect(msg).to be_a(String)
      expect(msg).not_to be_empty
    end

    it 'uses first person and references the domain' do
      expect(msg).to match(/I've been getting|I reset/i)
    end

    it 'invites the partner to clarify' do
      expect(msg).to match(/What works|what would you prefer/i)
    end

    it 'fires every time — no deduplication' do
      described_class.pain_revert_acknowledgment(identity: identity, domain: domain)
      msg2 = described_class.pain_revert_acknowledgment(identity: identity, domain: domain)
      expect(msg2).to be_a(String)
    end
  end

  # --- graduation_acknowledgment ---

  describe '.graduation_acknowledgment' do
    subject(:msg) { described_class.graduation_acknowledgment(identity: identity) }

    it 'returns a non-empty string on first call' do
      expect(msg).to be_a(String)
      expect(msg).not_to be_empty
    end

    it 'returns nil on second call for same identity' do
      described_class.graduation_acknowledgment(identity: identity)
      expect(msg).to be_nil
    end

    it 'fires for different identities independently' do
      described_class.graduation_acknowledgment(identity: identity)
      msg2 = described_class.graduation_acknowledgment(identity: 'other-person')
      expect(msg2).to be_a(String)
    end

    it 'sounds like a colleague, not a product' do
      result = described_class.graduation_acknowledgment(identity: 'fresh')
      expect(result).not_to match(/preferences.*saved|updated|stored/i)
    end
  end

  # --- onboarding_frame ---

  describe '.onboarding_frame' do
    subject(:frame) { described_class.onboarding_frame(identity: identity) }

    it 'returns a non-empty string on first call' do
      expect(frame).to be_a(String)
      expect(frame).not_to be_empty
    end

    it 'mentions local storage' do
      expect(frame).to match(/local|this machine|stored/i)
    end

    it 'mentions termination option' do
      expect(frame).to match(/end this|any time/i)
    end

    it 'returns nil on second call for same identity' do
      described_class.onboarding_frame(identity: identity)
      expect(frame).to be_nil
    end

    it 'fires for different identities independently' do
      described_class.onboarding_frame(identity: identity)
      msg2 = described_class.onboarding_frame(identity: 'fresh-partner')
      expect(msg2).to be_a(String)
    end
  end

  # --- epistemic_qualifier ---

  describe '.epistemic_qualifier' do
    context 'when no synapse and no imprint' do
      it 'returns nil — confident baseline' do
        expect(described_class.epistemic_qualifier(identity: identity, domain: domain)).to be_nil
      end
    end

    context 'with an observe-tier synapse for the domain' do
      before do
        # observe tier = confidence < 0.3 — emergent starts at 0.3 but we force lower
        Legion::Gaia::BehavioralSynapse.crystallize(
          identity: identity, domain: domain, directive: 'be brief', origin: 'emergent'
        )
        # Force confidence below 0.3 so it sits in :observe tier
        entry = Legion::Gaia::BehavioralSynapse.for(identity: identity, domain: domain)
        entry[:confidence] = 0.15 if entry
      end

      it 'returns a qualifier string' do
        # Stub the synapse lookup to return observe-tier entry
        allow(Legion::Gaia::BehavioralSynapse).to receive(:for)
          .with(identity: identity, domain: domain)
          .and_return({ confidence: 0.15, domain: domain, directive: 'be brief', id: 'x', status: 'active',
                        origin: 'emergent', consecutive_failures: 0, consecutive_successes: 0,
                        last_reinforced_at: nil })

        result = described_class.epistemic_qualifier(identity: identity, domain: domain)
        expect(result).to be_a(String)
      end
    end

    context 'with no domain specified' do
      it 'does not raise' do
        expect { described_class.epistemic_qualifier(identity: identity) }.not_to raise_error
      end

      it 'returns nil when no imprint active' do
        expect(described_class.epistemic_qualifier(identity: identity)).to be_nil
      end
    end
  end
end
