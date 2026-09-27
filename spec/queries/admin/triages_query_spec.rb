require "rails_helper"

# F-05.8: triagens iniciadas no período, conclusão e quebra por versão de
# protocolo — só contagens, nunca respostas (LGPD).
RSpec.describe Admin::TriagesQuery do
  def period = Admin::Api::Period.parse(key: "7d", from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])

  def protocol!(name, version, status)
    ProtocolDefinition.create!(
      name: name, version: version, status: status,
      definition: {
        "name" => name, "version" => version, "start_step_id" => "s1",
        "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                       "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 1, "false" => 0 } } ],
        "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
      }
    )
  end

  def triage!(protocol, status:, created_at: 2.hours.ago)
    conv = Conversation.create!(phone: "+55419#{SecureRandom.random_number(10**8).to_s.rjust(8, "0")}", state: "consented")
    Triage.create!(conversation: conv, protocol_definition: protocol, protocol_name: protocol.name, status: status,
                   answers: { "s1" => "segredo-clinico" }, created_at: created_at,
                   completed_at: status == "completed" ? created_at + 5.minutes : nil)
  end

  let!(:v1) { protocol!("resp", 1, "retired") }
  let!(:v2) { protocol!("resp", 2, "active") }

  before do
    triage!(v2, status: "completed")
    triage!(v2, status: "completed")
    triage!(v2, status: "in_progress")
    triage!(v1, status: "completed")
    triage!(v2, status: "completed", created_at: 40.days.ago)
  end

  it "counts started and completed triages in the period and the completion rate" do
    out = described_class.call(period: period)

    expect(out).to include(started: 4, completed: 3, completionRate: 75.0)
  end

  it "splits by protocol version with share and status, largest first" do
    out = described_class.call(period: period)

    expect(out[:byProtocol]).to eq([
      { version: "resp · 2", count: 3, share: 75, status: "active" },
      { version: "resp · 1", count: 1, share: 25, status: "retired" }
    ])
  end

  it "never carries the answers" do
    expect(described_class.call(period: period).to_json).not_to include("segredo-clinico")
  end
end
