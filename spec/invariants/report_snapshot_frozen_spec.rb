require "rails_helper"

# Módulo 04, critério de fechamento (ADR 0010):
#   - mudança de protocolo não muda relatório antigo;
#   - GET /r/:token jamais recalcula — lê só o snapshot congelado;
#   - caso clínico de regressão: relatório gerado sob uma versão do protocolo
#     municipal continua idêntico, byte a byte, depois de publicar e ativar a
#     versão seguinte.
#
# Versões de protocolo são inteiras (protocol_definitions.version); "1.2.0" e
# "1.3.0" do critério viram as versões 120 e 130 do protocolo "municipal".
RSpec.describe "Invariante: relatório congelado (ADR 0010)", type: :request do
  include ActiveJob::TestHelper

  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  # with_city do IdempotentConsumer procura a cidade no catálogo: em request
  # spec, city_request_auth.rb já registrou TEST_CITY_A (mesma sessão do
  # exemplo, city_test_databases.rb), então o job enxerga o que o exemplo grava.

  def v_1_2_0 = 120
  def v_1_3_0 = 130

  def municipal_definition(version, recommendation)
    {
      "name" => "municipal", "version" => version, "start_step_id" => "febre",
      "steps" => [
        { "id" => "febre", "prompt" => "Febre alta?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                     "priority_map" => { "baixa" => 9, "alta" => 2 } },
      "recommendations" => {
        "alta" => recommendation,
        "baixa" => { "title" => "Cuidados em casa", "body" => "Repouso e hidratação." }
      }
    }
  end

  def rec_1_2_0 = { "title" => "Procure a UBS hoje", "body" => "Febre alta pede avaliação no mesmo dia." }
  def rec_1_3_0 = { "title" => "Vá à UPA agora", "body" => "Nova diretriz: febre alta vai direto à UPA." }

  def consented_conversation
    convo = Conversation.create!(phone: "+55419#{rand(10_000_000..99_999_999)}", state: :consented)
    convo.consents.create!(
      version: Consents.current_version,
      policy_text_sha: Consents.policy_text_sha(Consents.current_version),
      given_at: 1.minute.ago, channel: "whatsapp", evidence: { text: "sim" }
    )
    convo
  end

  # Caminho real: CompleteTriage → triage.completed → GenerateReportJob (perform
  # completo, com dedup) → snapshot. Só o GenerateReportJob roda aqui.
  def complete_triage_under(protocol, answer: "true")
    triage = Triage.create!(conversation: consented_conversation, protocol_definition: protocol,
                            protocol_name: protocol.name, status: :in_progress,
                            current_step: "febre", answers: {})
    perform_enqueued_jobs(only: GenerateReportJob) do
      expect(CompleteTriage.call(triage: triage, answer: answer)).to be_ok
    end
    triage.reload
  end

  def publisher
    @publisher ||= User.create!(email_address: "pub-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "protocol_publisher", granted_at: Time.current)
    end
  end

  # Ciclo assinado de verdade (ADR 0016): duas assinaturas de publicação,
  # Publish; duas de ativação, Activate (que demove a vigente a published).
  def publish_and_activate!(protocol)
    2.times { sign!(protocol, purpose: "publication", by: make_reviewer!) }
    expect(Protocols::Publish.call(name: protocol.name, version: protocol.version, by: publisher)).to be_ok
    2.times { sign!(protocol, purpose: "activation", by: make_reviewer!) }
    expect(Protocols::Activate.call(name: protocol.name, version: protocol.version, by: publisher)).to be_ok
  end

  def read_report(token)
    get "/r/#{token}"
    expect(response).to have_http_status(:ok)
    response.body
  end

  it "caso clínico: relatório gerado na municipal 1.2.0 continua byte a byte igual depois de ativar a 1.3.0" do
    v120 = ProtocolDefinition.create!(name: "municipal", version: v_1_2_0, status: "active",
                                      definition: municipal_definition(v_1_2_0, rec_1_2_0))
    triage = complete_triage_under(v120)
    snapshot = ReportSnapshot.find_by!(triage_id: triage.id)
    before = read_report(snapshot.token)
    expect(JSON.parse(before)).to include("tier" => "alta", "recommendation" => rec_1_2_0)

    v130 = ProtocolDefinition.create!(name: "municipal", version: v_1_3_0, status: "in_review",
                                      definition: municipal_definition(v_1_3_0, rec_1_3_0))
    publish_and_activate!(v130)
    expect(v130.reload.status).to eq("active")
    expect(v120.reload.status).to eq("published")

    # A troca de versão é real: uma triagem nova já sai com a diretriz da 1.3.0.
    fresh = complete_triage_under(v130)
    expect(ReportSnapshot.find_by!(triage_id: fresh.id).payload["recommendation"]).to eq(rec_1_3_0)

    expect(read_report(snapshot.token)).to eq(before)
    expect(snapshot.reload.protocol_definition_id).to eq(v120.id)
  end

  it "mudar a triagem e a definição do protocolo depois não muda o que /r/:token responde" do
    protocol = ProtocolDefinition.create!(name: "municipal", version: v_1_2_0, status: "active",
                                          definition: municipal_definition(v_1_2_0, rec_1_2_0))
    triage = complete_triage_under(protocol)
    snapshot = ReportSnapshot.find_by!(triage_id: triage.id)
    before = read_report(snapshot.token)

    # Sem modelo de propósito: simula a pior hipótese (linha editada por fora).
    Triage.where(id: triage.id).update_all(tier: "baixa", priority: 9,
                                           outcome: { "tier" => "baixa", "priority" => 9, "trail" => [] })
    ProtocolDefinition.where(id: protocol.id)
                      .update_all(definition: municipal_definition(v_1_2_0, rec_1_3_0))

    expect(read_report(snapshot.token)).to eq(before)
  end

  it "/r/:token não toca o motor de triagem, a triagem nem a definição do protocolo" do
    protocol = ProtocolDefinition.create!(name: "municipal", version: v_1_2_0, status: "active",
                                          definition: municipal_definition(v_1_2_0, rec_1_2_0))
    snapshot = ReportSnapshot.find_by!(triage_id: complete_triage_under(protocol).id)

    expect(Protocols).not_to receive(:fetch)
    expect_any_instance_of(Protocols::Protocol).not_to receive(:evaluate)
    queried = []
    callback = ->(*, payload) { queried << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { read_report(snapshot.token) }

    expect(queried.grep(/\btriages\b|\bprotocol_definitions\b/)).to be_empty
  end
end
