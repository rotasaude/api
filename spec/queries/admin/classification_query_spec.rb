require "rails_helper"

# F-05.9: o painel Classificação lê os tiers que os protocolos da cidade de fato
# produzem (vocabulário livre do autor), a urgência pela mesma régua do alerta
# (Protocols::Urgency: priority <= URGENT_MAX_PRIORITY) e o modo de scoring da
# versão do protocolo em que cada triagem terminou.
RSpec.describe Admin::ClassificationQuery do
  def period = Admin::Api::Period.parse(key: "7d", from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])

  def definition(name, type)
    scoring =
      if type == "weighted"
        { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
          "priority_map" => { "baixa" => 9, "alta" => 1 } }
      else
        { "type" => "decision_table", "rules" => [], "default" => { "tier" => "indefinido", "priority" => 5 } }
      end
    {
      "name" => name, "version" => 1, "start_step_id" => "s1",
      "steps" => [
        { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
      ],
      "scoring" => scoring
    }
  end

  let!(:weighted) { ProtocolDefinition.create!(name: "resp", version: 1, status: "active", definition: definition("resp", "weighted")) }
  let!(:table)    { ProtocolDefinition.create!(name: "dor", version: 1, status: "active", definition: definition("dor", "decision_table")) }

  def triage!(protocol, tier:, priority:, completed_at: 1.hour.ago, status: "completed")
    conv = Conversation.create!(phone: "+55419#{SecureRandom.random_number(10**8).to_s.rjust(8, "0")}", state: "consented")
    Triage.create!(conversation: conv, protocol_definition: protocol, protocol_name: protocol.name,
                   status: status, tier: tier, priority: priority, answers: {}, completed_at: completed_at)
  end

  before do
    triage!(weighted, tier: "alta",  priority: 1)
    triage!(weighted, tier: "alta",  priority: 1)
    triage!(weighted, tier: "baixa", priority: 9)
    triage!(table,    tier: "indefinido", priority: 5)
    triage!(weighted, tier: "alta",  priority: 1, completed_at: 30.days.ago) # fora do período
    triage!(weighted, tier: nil, priority: nil, status: "in_progress", completed_at: nil)
  end

  it "counts the tiers the protocols actually produce, most urgent first" do
    out = described_class.call(period: period)

    expect(out[:tiers].map { |t| [ t[:key], t[:count] ] }).to eq([ [ "alta", 2 ], [ "indefinido", 1 ], [ "baixa", 1 ] ])
    expect(out[:tiers].first[:tone]).to eq("down")
  end

  it "counts urgent cases with the alert's own rule, not priority == true" do
    out = described_class.call(period: period)

    expect(out[:urgent]).to eq(2)
    expect(out[:urgentMaxPriority]).to eq(Protocols::Urgency.max_priority)
  end

  it "pivots tier counts per protocol version with the real tier names" do
    out = described_class.call(period: period)

    expect(out[:tierKeys]).to eq(%w[alta indefinido baixa])
    expect(out[:byProtocol]).to contain_exactly(
      { protocol: "resp · 1", counts: { "alta" => 2, "baixa" => 1 } },
      { protocol: "dor · 1",  counts: { "indefinido" => 1 } }
    )
  end

  it "splits by the scoring mode of the protocol version each triage used" do
    out = described_class.call(period: period)

    expect(out[:byMode].map { |m| [ m[:mode], m[:count] ] }).to contain_exactly([ "weighted", 3 ], [ "decision_table", 1 ])
  end

  it "samples triages with the integer priority and the version's mode, never the answers" do
    out = described_class.call(period: period)

    sample = out[:sampleTriages]
    expect(sample.size).to eq(4)
    expect(sample.map { |s| s[:priority] }).to all(be_a(Integer))
    expect(sample.map { |s| s[:mode] }).to include("weighted", "decision_table")
    expect(sample.flat_map(&:keys).uniq).to contain_exactly(:id, :tier, :priority, :urgent, :mode, :protocol, :at)
  end
end
