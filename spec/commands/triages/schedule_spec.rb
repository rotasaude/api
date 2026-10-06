require "rails_helper"

# ADR 0029 §5.2 (spec §9 "Pedido da triagem"): primeira regra que casa; urgente
# nunca; unidade de referência do bairro ou fila sem unidade; não duplica;
# tipo inexistente não perde o pedido.
RSpec.describe Triages::Schedule do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset; Rails.cache.clear }

  let(:rules) do
    [ { "when" => { "eq" => ["q1", "false"] }, "appointment_type" => "consulta_enfermagem", "priority" => "routine", "due_in_days" => 60 },
      { "when" => { "gte" => ["outcome.score", 4] }, "appointment_type" => "consulta_medica", "priority" => "priority", "due_in_days" => 7 },
      { "when" => { "gte" => ["outcome.score", 1] }, "appointment_type" => "retorno", "priority" => "routine", "due_in_days" => 30 } ]
  end
  let(:neighborhood) { Neighborhood.create!(name: "Batel", source: "seed") }
  let(:unit) { create_unit("UBS Batel").tap { |u| NeighborhoodCoverage.create!(neighborhood: neighborhood, health_unit: u) } }
  let(:par) { profiled_citizen!(age: 70, neighborhood: neighborhood) }

  def complete(citizen, answer, protocol = "saude-do-idoso")
    started = start_for!(citizen, protocol).payload
    Citizens::SubmitAnswer.call(conversation: started[:conversation], answer: answer, idempotency_key: SecureRandom.uuid)
    started[:triage].reload
  end

  def requests_of(citizen) = AppointmentRequest.where(citizen: citizen)

  it "a primeira regra que casa gera o pedido na unidade de referência, com evento só de ids" do
    unit
    active_protocol!("saude-do-idoso", scheduling: rules)
    triage = complete(par, "true")
    request = requests_of(par).sole
    expect(request).to have_attributes(kind: "triage", origin_triage_id: triage.id, root_triage_id: triage.id,
                                       origin_attendance_id: nil, origin_unit_id: nil, target_unit_id: unit.id,
                                       appointment_type_key: "consulta_medica", priority: "priority",
                                       due_on: Time.zone.today + 7, status: "open")
    expect(DomainEvent.where(name: "appointment_request.created_from_triage").sole.payload)
      .to eq("request_id" => request.id, "triage_id" => triage.id)
  end

  it "nenhuma regra: só orientação; resultado urgente: nunca" do
    active_protocol!("saude-do-idoso", scheduling: [ rules[1] ],
                                       priority_when: [ { "when" => { "eq" => ["q1", "true"] }, "priority" => 1 } ])
    expect(complete(par, "true").priority).to eq(1)
    expect(requests_of(par)).to be_empty
    complete(par, "false")
    expect(requests_of(par)).to be_empty
  end

  it "sem bairro, ou bairro sem unidade de referência: fila sem unidade" do
    active_protocol!("saude-do-idoso", scheduling: rules)
    sem_bairro = profiled_citizen!(age: 70, phone: "+5541977776666")
    complete(sem_bairro, "true")
    expect(requests_of(sem_bairro).sole.target_unit_id).to be_nil

    descoberto = Neighborhood.create!(name: "Sem Cobertura", source: "seed")
    sem_unidade = profiled_citizen!(age: 70, phone: "+5541977775555", neighborhood: descoberto)
    complete(sem_unidade, "true")
    expect(requests_of(sem_unidade).sole.target_unit_id).to be_nil
  end

  it "pedido vivo do mesmo tipo: não duplica; prazo menor, prioridade maior, triagem ligada" do
    unit
    active_protocol!("saude-do-idoso", scheduling: [ rules[1].merge("priority" => "routine", "due_in_days" => 30) ])
    active_protocol!("saude-do-idoso-2", scheduling: [ rules[1] ])
    first = complete(par, "true")
    request = requests_of(par).sole
    second = complete(par, "true", "saude-do-idoso-2")
    expect(requests_of(par).sole.id).to eq(request.id)
    expect(request.reload).to have_attributes(due_on: Time.zone.today + 7, priority: "priority", origin_triage_id: first.id)
    expect(request.request_triages.pluck(:triage_id)).to eq([ second.id ])
    expect(DomainEvent.where(name: "appointment_request.merged_triage").sole.payload)
      .to eq("request_id" => request.id, "triage_id" => second.id)
  end

  it "a fusão nunca afrouxa: prazo maior e prioridade menor não mudam o pedido" do
    unit
    active_protocol!("saude-do-idoso", scheduling: [ rules[1] ])
    active_protocol!("saude-do-idoso-2", scheduling: [ rules[1].merge("priority" => "routine", "due_in_days" => 60) ])
    complete(par, "true")
    complete(par, "true", "saude-do-idoso-2")
    expect(requests_of(par).sole).to have_attributes(due_on: Time.zone.today + 7, priority: "priority")
  end

  it "pedido do mesmo tipo já marcado (scheduled) também recebe a fusão, sem pedido novo" do
    unit
    active_protocol!("saude-do-idoso", scheduling: [ rules[1] ])
    complete(par, "true")
    request = requests_of(par).sole
    request.update!(status: "scheduled")
    second = complete(par, "true")
    expect(requests_of(par).sole.id).to eq(request.id)
    expect(request.request_triages.pluck(:triage_id)).to eq([ second.id ])
  end

  it "corrida: o índice único recusa o segundo pedido e a triagem cai na fusão" do
    unit
    active_protocol!("saude-do-idoso", scheduling: [ rules[1] ])
    first = complete(par, "true")
    request = requests_of(par).sole
    calls = 0
    allow(described_class).to receive(:merge).and_wrap_original do |original, *args|
      calls += 1
      calls == 1 ? nil : original.call(*args) # a 1ª busca "não vê" o pedido da outra conclusão
    end
    second = complete(par, "true")
    expect(calls).to eq(2)
    expect(requests_of(par).sole.id).to eq(request.id)
    expect(request.request_triages.pluck(:triage_id)).to eq([ second.id ])
    expect(request.reload.origin_triage_id).to eq(first.id)
  end

  it "regra sem prazo ou com prazo inválido: +30 dias, o padrão do pedido do atendimento" do
    unit
    active_protocol!("saude-do-idoso", scheduling: [ rules[1].except("due_in_days") ])
    active_protocol!("saude-do-idoso-2", scheduling: [ rules[1].merge("appointment_type" => "retorno",
                                                                      "due_in_days" => "abc") ])
    complete(par, "true")
    complete(par, "true", "saude-do-idoso-2")
    expect(requests_of(par).pluck(:appointment_type_key, :due_on))
      .to contain_exactly([ "consulta_medica", Time.zone.today + 30 ], [ "retorno", Time.zone.today + 30 ])
  end

  it "tipo inexistente na cidade: o pedido nasce com a key (nenhuma necessidade some)" do
    active_protocol!("saude-do-idoso", scheduling: [ rules[1].merge("appointment_type" => "geriatria") ])
    complete(par, "true")
    expect(requests_of(par).sole.appointment_type_key).to eq("geriatria")
  end

  it "conversa sem cidadão (WhatsApp) não gera pedido" do
    protocol = active_protocol!("saude-do-idoso", scheduling: rules)
    conversation = Conversation.create!(channel: "whatsapp", phone: "5541900001111", state: "consented")
    triage = Triage.create!(conversation: conversation, protocol_definition: protocol, protocol_name: protocol.name,
                            status: "completed", answers: { "q1" => "true" })
    outcome = Struct.new(:tier, :score, :priority, :terminal?).new("media", 4, 5, true)
    expect(described_class.call(triage: triage, outcome: outcome)).to be_nil
    expect(AppointmentRequest.count).to eq(0)
  end
end
