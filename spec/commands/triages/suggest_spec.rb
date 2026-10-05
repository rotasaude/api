require "rails_helper"

# ADR 0027 (spec 2026-10-05 §5.3): na conclusão, cada suggestions[] cujo when
# é verdadeiro e cujo protocolo está available para o par vira uma sugestão
# pending (uma por protocolo por par). Urgente nunca sugere. Nunca para si.
RSpec.describe Triages::Suggest do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:to_deep) { [ { "protocol" => "saude-mental-aprofundada", "when" => { "gte" => ["outcome.score", 4] } } ] }
  let!(:deep) { active_protocol!("saude-mental-aprofundada", offer: { "title" => "Aprofundamento" }) }
  let(:par) { profiled_citizen!(age: 30) }

  def complete(name, answer)
    started = start_for!(par, name).payload
    Citizens::SubmitAnswer.call(conversation: started[:conversation], answer: answer, idempotency_key: SecureRandom.uuid)
    started[:triage].reload
  end

  def pending = TriageSuggestion.status_pending.where(citizen_id: par.id)

  it "pontuação alta sugere, com evento só de ids" do
    active_protocol!("saude-mental", suggestions: to_deep)
    triage = complete("saude-mental", "true")
    suggestion = pending.sole
    expect(suggestion).to have_attributes(protocol_name: "saude-mental-aprofundada", source_triage_id: triage.id)
    expect(DomainEvent.where(name: "triage.suggested").sole.payload).to eq(
      "triage_id" => triage.id, "suggestion_id" => suggestion.id, "protocol_name" => "saude-mental-aprofundada"
    )
  end

  it "when falso não sugere" do
    active_protocol!("saude-mental", suggestions: to_deep)
    complete("saude-mental", "false")
    expect(pending).to be_empty
  end

  it "resultado urgente nunca sugere" do
    active_protocol!("saude-mental", suggestions: to_deep,
                                     priority_when: [ { "when" => { "eq" => ["q1", "true"] }, "priority" => 1 } ])
    triage = complete("saude-mental", "true")
    expect(triage.priority).to eq(1)
    expect(pending).to be_empty
    expect(DomainEvent.where(name: "triage.suggested")).to be_empty
  end

  it "protocolo sugerido fora de oferta (pausado) ou inexistente não sugere" do
    TriageOffer.create!(protocol_name: "saude-mental-aprofundada", enabled: false,
                        updated_by_user: staff_with("pausa-#{SecureRandom.hex(3)}@cidade.gov.br"))
    active_protocol!("saude-mental", suggestions: to_deep + [ { "protocol" => "fantasma", "when" => { "eq" => ["q1", "true"] } } ])
    complete("saude-mental", "true")
    expect(pending).to be_empty
  end

  it "uma pendente por protocolo: a segunda conclusão não duplica nem falha" do
    active_protocol!("saude-mental", suggestions: to_deep + to_deep)
    complete("saude-mental", "true")
    complete("saude-mental", "true")
    expect(pending.count).to eq(1)
  end

  it "sugestão para o próprio protocolo gravada por fora é ignorada" do
    active_protocol!("saude-mental", suggestions: [ { "protocol" => "saude-mental", "when" => { "eq" => ["q1", "true"] } } ])
    complete("saude-mental", "true")
    expect(pending).to be_empty
  end

  it "conversa sem cidadão (WhatsApp) não sugere" do
    definition = active_protocol!("saude-mental", suggestions: to_deep)
    conversation = Conversation.create!(phone: "+5541911112222", state: :consented)
    triage = Triage.create!(conversation: conversation, protocol_definition: definition, protocol_name: "saude-mental",
                            status: "completed", answers: { "q1" => "true" }, completed_at: Time.current)
    outcome = Protocols::Outcome.terminal(trail: [], tier: "media", priority: 5, score: 4)
    expect(described_class.call(triage: triage, outcome: outcome)).to eq([])
  end
end
