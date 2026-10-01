require "rails_helper"

# ADR 0026: a trilha (imutável por 12 meses) só leva referência.
RSpec.describe "payload de triage.completed e triage.urgent" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  it "publica só o triage_id, sem respostas nem classificação" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    triage = completed_web_triage_for(citizen)

    event = DomainEvent.where(name: "triage.completed").find_by("payload->>'triage_id' = ?", triage.id)
    expect(event.payload).to eq("triage_id" => triage.id)
  end

  it "publica triage.urgent só com o triage_id" do
    definition = {
      "name" => "payload-urgente", "version" => 1, "start_step_id" => "febre",
      "steps" => [{ "id" => "febre", "prompt" => "Febre?", "answer_type" => "boolean",
                    "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }],
      "scoring" => { "type" => "weighted", "thresholds" => { "low" => 0, "high" => 5 },
                     "priority_map" => { "low" => 9, "high" => 1 } }
    }
    pd = ProtocolDefinition.create!(name: "payload-urgente", version: 1, status: "active", definition: definition)
    convo = Conversation.create!(phone: "+5511977770001", state: :consented)
    convo.consents.create!(version: Consents.current_version,
                           policy_text_sha: Consents.policy_text_sha(Consents.current_version),
                           given_at: 1.minute.ago, channel: "whatsapp", evidence: { text: "sim" })
    triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "payload-urgente",
                            status: :in_progress, current_step: "febre", answers: {})

    CompleteTriage.call(triage: triage, answer: "true")

    expect(triage.reload.priority).to eq(1)
    event = DomainEvent.where(name: "triage.urgent").find_by("payload->>'triage_id' = ?", triage.id)
    expect(event.payload).to eq("triage_id" => triage.id)
  end
end
