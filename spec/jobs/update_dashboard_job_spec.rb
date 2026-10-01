require "rails_helper"

# F-05.13: consumidor de triage.completed que mantém a projeção incremental
# (ADR 0010). Soma tier e total no dia da conclusão, uma vez por evento.
RSpec.describe UpdateDashboardJob, type: :job do
  # Mesmo slug/banco de TEST_CITY_A: o with_city do IdempotentConsumer reentra o
  # shard que o harness já abriu.
  let!(:city) do
    create(:city, slug: TEST_CITY_A.slug, status: "active", database_url: city_database_url("rota_saude_test_city_a"))
  end

  let!(:triage) do
    protocol = ProtocolDefinition.create!(
      name: "resp", version: 1, status: "active",
      definition: {
        "name" => "resp", "version" => 1, "start_step_id" => "s1",
        "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                       "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } } ],
        "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                       "priority_map" => { "baixa" => 9, "alta" => 1 } }
      }
    )
    conv = Conversation.create!(phone: "+5541900000123", state: "consented")
    Triage.create!(conversation: conv, protocol_definition: protocol, protocol_name: "resp", status: "completed",
                   tier: "alta", priority: 1, answers: {}, completed_at: Time.zone.parse("2026-09-10 10:00"))
  end

  def event_args(event_id: SecureRandom.uuid)
    { event_id: event_id, event_name: "triage.completed", city_slug: city.slug,
      payload: { "triage_id" => triage.id } }
  end

  def metrics = DashboardMetric.pluck(:dimension, :period, :key, :value)

  it "bumps the tier and the total on the completion day" do
    described_class.new.perform(**event_args)

    expect(metrics).to contain_exactly(
      [ "triages_by_tier", "2026-09-10", "alta",  1 ],
      [ "triages_total",   "2026-09-10", "total", 1 ]
    )
  end

  it "adds up across different events" do
    described_class.new.perform(**event_args)
    described_class.new.perform(**event_args)

    expect(DashboardMetric.find_by(dimension: "triages_total").value).to eq(2)
  end

  it "does not double-count a re-delivered event (ProcessedEvent dedup)" do
    args = event_args
    described_class.new.perform(**args)
    described_class.new.perform(**args)

    expect(DashboardMetric.find_by(dimension: "triages_total").value).to eq(1)
  end

  it "pula uma triagem anonimizada: nenhuma métrica é somada (ADR 0026)" do
    triage.update_columns(anonymized_at: Time.current, outcome: nil, tier: nil, priority: nil)

    expect { described_class.new.perform(**event_args) }.not_to raise_error
    expect(metrics).to be_empty
  end
end
