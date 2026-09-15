require "rails_helper"

RSpec.describe AlertMunicipalityJob, type: :job do
  include ActiveJob::TestHelper

  # Mesmo slug/database_url de TEST_CITY_A: with_city(city.slug) reentra o
  # shard que o harness já tem aberto (ver anonymize_revoked_triage_job_spec.rb).
  let!(:city) do
    create(:city, slug: TEST_CITY_A.slug, status: "active", database_url: city_database_url("rota_saude_test_city_a"))
  end

  def make_triage(completed_at:)
    pd = ProtocolDefinition.create!(name: "alert-demo", version: 1, status: "active", definition: {
      "name" => "alert-demo", "version" => 1, "start_step_id" => "s1",
      "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                    "branches" => { "true" => nil, "false" => nil } } ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 } }
    })
    convo = Conversation.create!(phone: "+551188", state: "completed")
    Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "alert-demo",
                   status: "completed", answers: {}, tier: "alta", priority: 1,
                   current_step: "s1", completed_at: completed_at)
  end

  # Check (fix round 1): antes, handle passava Time.current como occurred_at
  # para DispatchMunicipalityAlertJob -- o momento em que o CONSUMER rodou,
  # não o da triage. Isso fica errado especialmente num redispatch
  # (ResendPendingAlertsJob), que pode rodar horas/dias depois do evento
  # original: o e-mail mostraria "agora", não quando a triage urgente de fato
  # aconteceu. triage.completed_at já está setado (CompleteTriage chama
  # triage.complete! antes de publicar triage.urgent) e é o valor certo.
  it "passa o completed_at REAL da triage para DispatchMunicipalityAlertJob, não o momento em que o consumer rodou" do
    completed_at = 3.days.ago
    triage = CityConnection.with(city) { make_triage(completed_at: completed_at) }

    expect {
      described_class.new.perform(event_id: SecureRandom.uuid, event_name: "triage.urgent",
                                   city_slug: city.slug, payload: { "triage_id" => triage.id })
    }.to have_enqueued_job(DispatchMunicipalityAlertJob).with(hash_including(
      triage_id: triage.id,
      tier: "alta",
      priority: 1,
      occurred_at: completed_at.iso8601
    ))
  end
end
