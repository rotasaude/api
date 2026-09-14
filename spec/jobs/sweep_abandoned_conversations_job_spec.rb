require "rails_helper"

RSpec.describe SweepAbandonedConversationsJob, type: :job do
  def definition_hash
    {
      "name" => "sweep-demo", "version" => 1, "start_step_id" => "s1",
      "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                    "branches" => { "true" => nil, "false" => nil } }],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 } }
    }
  end

  def build_scenario(&block)
    pd = ProtocolDefinition.create!(name: "sweep-demo", version: 1, status: "active", definition: definition_hash)
    block.call(pd)
  end

  def make_convo(phone:, state:, updated_at:)
    c = Conversation.create!(phone: phone, state: state)
    c.update_columns(updated_at: updated_at)
    c
  end

  def make_triage(pd, convo, status:, updated_at:)
    t = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "sweep-demo", status: status)
    t.update_columns(updated_at: updated_at)
    t
  end

  # SweepAbandonedConversationsJob prepends EachCityJob, cujo #perform não é o
  # que carrega esta lógica de negócio (só itera cidades ativas) — chamamos o
  # corpo do job direto na conexão que o harness já abriu, como 5b já fez para
  # rebuild_dashboard_metrics_job_spec/reconcile_consents_job_spec.
  def call_body(**kwargs)
    described_class.instance_method(:perform).super_method.bind_call(described_class.new, **kwargs)
  end

  it "abandons an idle awaiting_consent conversation with no triage" do
    convo = make_convo(phone: "+551100", state: "awaiting_consent", updated_at: 30.hours.ago)
    call_body(idle_hours: 24)
    expect(Conversation.find(convo.id).state).to eq("abandoned")
  end

  it "abandons a consented conversation and aborts its stale in-progress triage" do
    convo = triage = nil
    build_scenario do |pd|
      convo = make_convo(phone: "+551101", state: "consented", updated_at: 30.hours.ago)
      triage = make_triage(pd, convo, status: "in_progress", updated_at: 30.hours.ago)
    end
    call_body(idle_hours: 24)
    expect(Conversation.find(convo.id).state).to eq("abandoned")
    expect(Triage.find(triage.id).status).to eq("aborted_by_timeout")
  end

  it "leaves a recent conversation untouched" do
    convo = make_convo(phone: "+551102", state: "awaiting_consent", updated_at: 1.hour.ago)
    call_body(idle_hours: 24)
    expect(Conversation.find(convo.id).state).to eq("awaiting_consent")
  end

  it "leaves a conversation that completed a triage untouched" do
    convo = nil
    build_scenario do |pd|
      convo = make_convo(phone: "+551103", state: "consented", updated_at: 30.hours.ago)
      make_triage(pd, convo, status: "completed", updated_at: 30.hours.ago)
    end
    call_body(idle_hours: 24)
    expect(Conversation.find(convo.id).state).to eq("consented")
  end

  it "leaves a conversation with a fresh in-progress triage untouched" do
    convo = nil
    build_scenario do |pd|
      convo = make_convo(phone: "+551104", state: "consented", updated_at: 30.hours.ago)
      make_triage(pd, convo, status: "in_progress", updated_at: 1.hour.ago)
    end
    call_body(idle_hours: 24)
    expect(Conversation.find(convo.id).state).to eq("consented")
  end

  it "roda uma vez por cidade ATIVA (EachCityJob): abandona em AMBAS as cidades" do
    city_a = create(:city, database_url: city_database_url("rota_saude_test_city_a"))
    city_b = create(:city, database_url: city_database_url("rota_saude_test_city_b"))

    convo_a = CityConnection.with(city_a) { make_convo(phone: "+551200", state: "awaiting_consent", updated_at: 30.hours.ago) }
    convo_b = CityConnection.with(city_b) { make_convo(phone: "+551201", state: "awaiting_consent", updated_at: 30.hours.ago) }

    described_class.new.perform(idle_hours: 24)

    expect(CityConnection.with(city_a) { Conversation.find(convo_a.id).state }).to eq("abandoned")
    expect(CityConnection.with(city_b) { Conversation.find(convo_b.id).state }).to eq("abandoned")
  end

  it "não visita uma cidade que não está active" do
    suspended = create(:city, database_url: city_database_url("rota_saude_test_city_b"), status: "suspended")
    convo = CityConnection.with(suspended) { make_convo(phone: "+551202", state: "awaiting_consent", updated_at: 30.hours.ago) }

    described_class.new.perform(idle_hours: 24)

    expect(CityConnection.with(suspended) { Conversation.find(convo.id).state }).to eq("awaiting_consent")
  end
end
