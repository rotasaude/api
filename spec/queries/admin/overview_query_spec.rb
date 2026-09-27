require "rails_helper"

# F-05.4: os cinco KPIs do Overview, ao vivo (ADR 0022), na cidade do host.
RSpec.describe Admin::OverviewQuery do
  def period = Admin::Api::Period.parse(key: "7d", from: nil, to: nil, tz: ActiveSupport::TimeZone["America/Sao_Paulo"])

  let!(:protocol) do
    ProtocolDefinition.create!(
      name: "resp", version: 1, status: "active",
      definition: {
        "name" => "resp", "version" => 1, "start_step_id" => "s1",
        "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                       "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } } ],
        "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                       "priority_map" => { "baixa" => 9, "alta" => 1 } }
      }
    )
  end

  def triage!(status:, priority: nil, created_at: 2.hours.ago, completed_at: nil)
    conv = Conversation.create!(phone: "+55419#{SecureRandom.random_number(10**8).to_s.rjust(8, "0")}", state: "consented")
    Triage.create!(conversation: conv, protocol_definition: protocol, protocol_name: "resp", status: status,
                   priority: priority, answers: {}, created_at: created_at, completed_at: completed_at)
  end

  def kpi(id) = described_class.call(period: period)[:kpis].find { |k| k[:id] == id }

  before do
    triage!(status: "completed", priority: 1, completed_at: 1.hour.ago)
    triage!(status: "completed", priority: 9, completed_at: 1.hour.ago)
    triage!(status: "completed", priority: 1, created_at: 40.days.ago, completed_at: 40.days.ago)
    triage!(status: "in_progress")
  end

  it "returns the five KPIs, every one tagged live" do
    kpis = described_class.call(period: period)[:kpis]

    expect(kpis.map { |k| k[:id] }).to eq(%w[done active urgent completion failed])
    expect(kpis.map { |k| k[:source] }.uniq).to eq([ "live" ])
  end

  it "counts triages completed in the period" do
    expect(kpi("done")[:value]).to eq(2)
  end

  it "counts urgent triages with the alert's own rule (Protocols::Urgency)" do
    expect(kpi("urgent")).to include(value: 1, tone: "warn")
  end

  it "computes the completion rate over triages started in the period" do
    expect(kpi("completion")[:value]).to eq(66.7)
  end

  it "counts active conversations touched in the last hour" do
    Conversation.create!(phone: "+5541900000001", state: "awaiting_consent")
    Conversation.create!(phone: "+5541900000002", state: "abandoned")

    expect(kpi("active")[:value]).to eq(5)
  end

  it "counts the failed jobs of this city's own queue" do
    expect(kpi("failed")).to include(value: 0, tone: "ok")
  end
end
