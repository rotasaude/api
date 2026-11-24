require "rails_helper"

# Módulo 35b, Task 9 (ADR 0054; contrato §4; Q6, Q13–Q15; Review Focus 2): a
# manifestação de zoonoses (com `zoonoses_subtype`) nasce, na mesma transação
# do registro do 33, classificada pelo sistema no assunto
# `zoonoses.<subtipo>` e encaminhada pelo sistema à UVZ ativa mais antiga, com
# o extrato = o texto do cidadão e a demanda `open`. Sem UVZ ativa, ou sem
# ninguém da equipe, fica `in_analysis` já classificada. Se o encaminhamento
# falhar depois da classificação, o savepoint volta só o encaminhamento: o
# registro do cidadão nunca se perde, e nunca há demanda sem encaminhamento.
RSpec.describe Zoonoses::OpenDemand, type: :model do
  let!(:city) do
    zoonoses_city!
    ombudsman_city!(anonymous: true)
  end
  let(:phone) { "+5541998765432" }
  let(:session) { CitizenSession.start!(phone: phone).first }
  let(:citizen) { web_citizen!(phone: phone) }
  let(:text) { "Vi escorpiões no quintal da casa ao lado, perto das crianças." }
  let(:address) { "Rua das Acácias, 120, fundos, Vila Nova" }
  let(:now) { Time.zone.local(2026, 11, 23, 10, 0) }
  let!(:uvz) { uvz_unit! }
  let!(:team) { zoonoses_team! }

  def web(mode: "identified", kind: "request", subtype: "scorpion", body: text, place: address)
    Ombudsman::Register.call(attrs: { "kind" => kind, "identification_mode" => mode, "body" => body, "zoonoses_subtype" => subtype,
                                      "place_address" => place },
                             channel: "web", citizen: citizen, citizen_session: session, zoonoses: true, now: now)
  end

  def anonymous(subtype: "scorpion", body: text)
    Ombudsman::RegisterAnonymous.call(body: body, health_unit_id: nil, zoonoses_subtype: subtype, place_address: address,
                                      zoonoses: true, now: now)
  end

  def manifestation_of(result)
    expect(result).to be_ok
    result.payload.fetch(:manifestation).reload
  end

  def subject_for(subtype) = OmbudsmanSubject.find_by!(code: "zoonoses.#{subtype}")

  it "os três modos (identificado, preservado, anônimo) chegam forwarded com a demanda open, o extrato = o texto e o subtipo na demanda" do
    results = { "identified" => web(mode: "identified", subtype: "scorpion"), "preserved" => web(mode: "preserved", subtype: "bat"),
                "anonymous" => anonymous(subtype: "rodent") }
    expected = { "identified" => "scorpion", "preserved" => "bat", "anonymous" => "rodent" }

    results.each do |mode, result|
      m = manifestation_of(result)
      subtype = expected.fetch(mode)
      expect(m).to have_attributes(identification_mode: mode, state: "forwarded", subject_id: subject_for(subtype).id,
                                   place_address: address, body: text)
      forwarding = OmbudsmanForwarding.where(ombudsman_manifestation_id: m.id).sole
      expect(forwarding).to have_attributes(health_unit_id: uvz.id, department_id: nil, extract: text, state: "pending",
                                            created_by_user_id: nil, created_by_system: true)
      demand = ZoonosesDemand.find_by!(ombudsman_forwarding_id: forwarding.id)
      expect(demand).to have_attributes(subtype: subtype, state: "open", version: 1, assigned_user_id: nil)
      expect(DomainEvent.where(name: "zoonoses_demand.opened").where("payload->>'zoonoses_demand_id' = ?", demand.id).sole.payload)
        .to eq("zoonoses_demand_id" => demand.id)
    end
    expect(OmbudsmanManifestation.find(results["anonymous"].payload[:manifestation].id).kind).to eq("report")
    expect(ZoonosesDemand.count).to eq(3)
  end

  it "texto de 4.000 com endereço de 300 → encaminhado, com o extrato inteiro (Q13)" do
    body = "a" * 4000
    m = manifestation_of(web(body: body, place: "R" * 300))
    expect(m.state).to eq("forwarded")
    expect(m.place_address.length).to eq(300)
    expect(OmbudsmanForwarding.where(ombudsman_manifestation_id: m.id).sole.extract).to eq(body)
    expect(ZoonosesDemand.count).to eq(1)
  end

  it "sem UVZ ativa → in_analysis com o assunto zoonoses.scorpion, sem encaminhamento" do
    uvz.update!(active: false)
    m = manifestation_of(web)
    expect(m).to have_attributes(state: "in_analysis", subject_id: subject_for("scorpion").id)
    expect(OmbudsmanForwarding.count).to eq(0)
    expect(ZoonosesDemand.count).to eq(0)
    expect(m.events.order(:created_at, :id).map { |e| [ e.kind, e.actor ] }).to eq([ %w[received citizen], %w[classified system] ])
  end

  it "UVZ sem ninguém da equipe → in_analysis classificada, sem encaminhamento" do
    team.memberships.each(&:revoke!)
    expect(Zoonoses::Access.team_user_ids).to be_empty
    m = manifestation_of(web)
    expect(m).to have_attributes(state: "in_analysis", subject_id: subject_for("scorpion").id)
    expect(OmbudsmanForwarding.count).to eq(0)
    expect(ZoonosesDemand.count).to eq(0)
  end

  it "duas UVZ → a de menor created_at" do
    newer = uvz_unit!
    older = uvz_unit!
    HealthUnit.where(id: older.id).update_all(created_at: uvz.created_at - 1.day)
    HealthUnit.where(id: newer.id).update_all(created_at: uvz.created_at + 1.day)
    m = manifestation_of(web)
    expect(OmbudsmanForwarding.where(ombudsman_manifestation_id: m.id).sole.health_unit_id).to eq(older.id)
  end

  it "evento classified e forwarded com actor system, sem usuário; os do 33 publicados só com ids" do
    m = manifestation_of(web)
    forwarding = OmbudsmanForwarding.where(ombudsman_manifestation_id: m.id).sole
    events = m.events.order(:created_at, :id).map { |e| [ e.kind, e.actor, e.actor_user_id, e.visible_to_citizen ] }
    expect(events).to eq([ [ "received", "citizen", nil, true ], [ "classified", "system", nil, false ],
                           [ "forwarded", "system", nil, false ] ])
    classified = m.events.find_by!(kind: "classified")
    expect(classified.data).to eq("changes" => { "subject_id" => [ nil, subject_for("scorpion").id ] })
    expect(m.events.find_by!(kind: "forwarded").data).to eq("forwarding_id" => forwarding.id)
    expect(DomainEvent.where(name: "ombudsman.forwarded").sole.payload)
      .to eq("manifestation_id" => m.id, "forwarding_id" => forwarding.id)
  end

  it "prazo = forwarding_days da configuração vigente" do
    OmbudsmanSetting.current.update!(forwarding_days: 7)
    m = manifestation_of(web)
    expect(OmbudsmanForwarding.where(ombudsman_manifestation_id: m.id).sole.due_on).to eq(now.to_date + 7)
  end

  # Review Focus 2: a UVZ é lida antes do encaminhamento; ela é desativada
  # no ponto da trava da manifestação pelo Forward (a segunda trava: a
  # primeira é a do Classify), depois da leitura e antes da conferência do
  # destino. O registro fica, classificado, e nada do encaminhamento.
  it "Review Focus 2: UVZ desativada entre a leitura e a trava → manifestação gravada em in_analysis, nenhuma demanda" do
    locks = 0
    allow(Ombudsman::Lock).to receive(:manifestation!).and_wrap_original do |original, id|
      locks += 1
      HealthUnit.where(id: uvz.id).update_all(active: false) if locks == 2
      original.call(id)
    end

    m = manifestation_of(web)
    expect(locks).to eq(2)
    expect(m).to have_attributes(state: "in_analysis", subject_id: subject_for("scorpion").id, body: text, place_address: address)
    expect(OmbudsmanForwarding.count).to eq(0)
    expect(ZoonosesDemand.count).to eq(0)
    expect(m.events.pluck(:kind)).to contain_exactly("received", "classified")
    expect(DomainEvent.where(name: %w[ombudsman.forwarded zoonoses_demand.opened]).count).to eq(0)
    expect(DomainEvent.where(name: "ombudsman.manifestation_received").count).to eq(1)
  end

  # Review Focus 2: a falha do banco DEPOIS de o encaminhamento gravado (na
  # criação da demanda) volta só o savepoint — o encaminhamento, o evento e o
  # ombudsman.forwarded —, e a manifestação fica classificada.
  it "Review Focus 2: falha na demanda depois do encaminhamento → o savepoint volta o encaminhamento; nunca demanda sem encaminhamento" do
    allow(ZoonosesDemand).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "simulada")
    m = manifestation_of(web)
    expect(m).to have_attributes(state: "in_analysis", subject_id: subject_for("scorpion").id)
    expect(OmbudsmanForwarding.count).to eq(0)
    expect(ZoonosesDemand.count).to eq(0)
    expect(m.events.pluck(:kind)).to contain_exactly("received", "classified")
    expect(DomainEvent.where(name: "ombudsman.forwarded").count).to eq(0)
  end

  # Review Focus 2: erro que não é do banco (KeyError, RuntimeError) na
  # garantia dos assuntos ou no encaminhamento também não leva o registro.
  it "Review Focus 2: erro fora do ActiveRecord nos assuntos → registro gravado received; no Forward → in_analysis classificada" do
    allow(Ombudsman::Subjects).to receive(:ensure_zoonoses!).and_raise(KeyError, "simulada")
    first = nil
    log = capture_log { first = manifestation_of(web) }
    expect(first).to have_attributes(state: "received", subject_id: nil, body: text, place_address: address)
    expect(log).to include("[Zoonoses::OpenDemand] not_forwarded manifestation_id=#{first.id}", "error=KeyError")
    expect(log).not_to include("simulada")

    allow(Ombudsman::Subjects).to receive(:ensure_zoonoses!).and_call_original
    allow(Ombudsman::Forward).to receive(:call).and_raise(RuntimeError, "simulada")
    second = manifestation_of(web)
    expect(second).to have_attributes(state: "in_analysis", subject_id: subject_for("scorpion").id)
    expect(OmbudsmanManifestation.count).to eq(2)
    expect(OmbudsmanForwarding.count).to eq(0)
    expect(ZoonosesDemand.count).to eq(0)
  end

  # Q34, no caminho automático (o Forward do sistema, by: nil): a manifestação
  # já encaminhada à UVZ, com o encaminhamento pending → 409
  # forwarding_already_pending, nada gravado; recusado o primeiro, o novo
  # passa e cria outra demanda.
  it "Q34: encaminhamento do sistema à UVZ com outro pending → forwarding_already_pending; depois da recusa → nova demanda" do
    m = manifestation_of(web)
    forward = lambda do
      Ombudsman::Forward.call(manifestation_id: m.id, expected_state: m.reload.state, department_id: nil, health_unit_id: uvz.id,
                              extract: m.body, by: nil, zoonoses: true, now: now)
    end
    refused = forward.call
    expect([ refused.reason, refused.details[:path] ]).to eq([ :forwarding_already_pending, "destination" ])
    expect(OmbudsmanForwarding.count).to eq(1)
    expect(ZoonosesDemand.count).to eq(1)

    declined = Ombudsman::DeclineForwarding.call(forwarding_id: OmbudsmanForwarding.sole.id, expected_state: "pending",
                                                 reason: "Endereço fora da área de atuação desta unidade.", by: responder!(uvz))
    expect(declined).to be_ok
    expect(forward.call).to be_ok
    expect(OmbudsmanForwarding.where(state: "pending").count).to eq(1)
    expect(ZoonosesDemand.count).to eq(2)
  end

  it "o log do registro não traz o endereço nem o texto" do
    log = capture_log { web }
    expect(log).not_to include(address)
    expect(log).not_to include(text)
  end
end
