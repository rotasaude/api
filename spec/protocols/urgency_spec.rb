require "rails_helper"

RSpec.describe Protocols::Urgency do
  def terminal(priority:, tier: "high")
    Protocols::Outcome.terminal(trail: [], tier: tier, priority: priority)
  end

  it "is urgent at the threshold" do
    expect(described_class.urgent?(terminal(priority: 1))).to be(true)
  end

  it "is not urgent above the threshold" do
    expect(described_class.urgent?(terminal(priority: 2))).to be(false)
    expect(described_class.urgent?(terminal(priority: 9))).to be(false)
  end

  it "is not urgent when priority is absent" do
    expect(described_class.urgent?(terminal(priority: nil))).to be(false)
  end

  it "is not urgent for a pending outcome" do
    pending_outcome = Protocols::Outcome.pending(trail: [], awaiting: :febre)
    expect(described_class.urgent?(pending_outcome)).to be(false)
  end

  it "is tier-agnostic" do
    %w[alta high urgente vermelho].each do |tier|
      expect(described_class.urgent?(terminal(priority: 1, tier: tier))).to be(true)
    end
  end

  it "never raises on garbage" do
    expect(described_class.urgent?(nil)).to be(false)
    expect(described_class.urgent?("nope")).to be(false)
  end

  it "honours URGENT_MAX_PRIORITY" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("URGENT_MAX_PRIORITY", 1).and_return("3")
    expect(described_class.urgent?(terminal(priority: 3))).to be(true)
    expect(described_class.urgent?(terminal(priority: 4))).to be(false)
  end

  it "falls back to the default when the override is garbage" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("URGENT_MAX_PRIORITY", 1).and_return("banana")
    expect(described_class.max_priority).to eq(1)
  end
end
