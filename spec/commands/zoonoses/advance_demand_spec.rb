require "rails_helper"

# Módulo 35b, Task 10 (ADR 0054; contrato §4, Q13, Q34): o andamento da
# demanda de zoonoses — schedule, inspect, close, decline, extend — com
# expected_version (409 demand_changed). close e decline respondem e recusam o
# encaminhamento do 33 (ReplyForwarding / DeclineForwarding com via_zoonoses);
# extend usa o ExtendForwarding, uma vez. Encaminhamento fora de pending → 409
# forwarding_changed. A equipe do centro responde sem o papel
# ombudsman_responder. Todo fim do encaminhamento ligado (a equipe, o
# respondente do 33 pelo inbox, o cancelamento da equipe da ouvidoria) fecha a
# demanda na mesma transação; só o close da equipe traz `outcome`.
RSpec.describe Zoonoses::AdvanceDemand, type: :model do
  let!(:city) do
    zoonoses_city!
    ombudsman_city!(anonymous: true)
  end
  let!(:uvz) { uvz_unit! }
  let!(:team) { zoonoses_team! }
  let(:today) { Time.zone.today }
  let(:closing) { "Vistoria feita, foco removido e orientação dada aos moradores." }
  let(:demand) { zoonoses_demand! }

  def advance(demand, action, by: team, **params)
    params = { "expected_version" => demand.reload.version }.merge(params.transform_keys(&:to_s)).reject { |_, value| value == :omit }
    described_class.call(demand: demand, action: action, params: params, by: by)
  end

  def refusal(result) = [ result.reason, result.details[:path] ]
  def forwarding_of(demand) = demand.reload.ombudsman_forwarding.reload
  def manifestation_of(demand) = forwarding_of(demand).ombudsman_manifestation.reload

  it "open → scheduled → inspected → closed responde o encaminhamento (replied) e a manifestação volta a in_analysis" do
    expect(manifestation_of(demand).state).to eq("forwarded")

    expect(advance(demand, "schedule", scheduled_on: (today + 2).iso8601)).to be_ok
    expect(demand.reload).to have_attributes(state: "scheduled", scheduled_on: today + 2, version: 2)

    expect(advance(demand, "inspect", inspected_on: today.iso8601, inspection_note: "Foco de escorpiões no entulho.")).to be_ok
    expect(demand.reload).to have_attributes(state: "inspected", inspected_on: today, inspection_note: "Foco de escorpiões no entulho.",
                                             version: 3)

    result = advance(demand, "close", outcome: "resolved", text: closing)
    expect(result).to be_ok
    expect(result.payload[:demand]).to eq(demand)
    expect(demand.reload).to have_attributes(state: "closed", outcome: "resolved", version: 4)
    expect(forwarding_of(demand)).to have_attributes(state: "replied", reply: closing, replied_by_user_id: team.id)
    expect(manifestation_of(demand).state).to eq("in_analysis")
    expect(DomainEvent.where(name: "zoonoses_demand.changed").pluck(:payload)).to eq([ { "zoonoses_demand_id" => demand.id } ] * 3)
    expect(DomainEvent.where(name: "ombudsman.forwarding_replied").sole.payload)
      .to eq("manifestation_id" => manifestation_of(demand).id, "forwarding_id" => forwarding_of(demand).id)
    expect(manifestation_of(demand).events.find_by!(kind: "forwarding_replied")).to have_attributes(actor: "staff", actor_user_id: team.id)

    expect(refusal(advance(demand, "decline", text: "Fora da área de atuação."))).to eq([ :forwarding_changed, nil ])
  end

  it "close direto de open também vale (orientação por telefone)" do
    expect(advance(demand, "close", outcome: "guidance", text: closing)).to be_ok
    expect(demand.reload).to have_attributes(state: "closed", outcome: "guidance")
  end

  it "close sem outcome → path outcome; texto de 19 → path text" do
    expect(refusal(advance(demand, "close", text: closing))).to eq([ :invalid_request, "outcome" ])
    expect(refusal(advance(demand, "close", outcome: "cured", text: closing))).to eq([ :invalid_request, "outcome" ])
    expect(refusal(advance(demand, "close", outcome: "resolved", text: "a" * 19))).to eq([ :invalid_request, "text" ])
    expect(refusal(advance(demand, "close", outcome: "resolved", text: "a" * 4001))).to eq([ :invalid_request, "text" ])
    expect(advance(demand, "close", outcome: "resolved", text: "a" * 20)).to be_ok
    expect(forwarding_of(demand).reply).to eq("a" * 20)
  end

  it "decline fecha sem outcome; o encaminhamento fica declined com o texto" do
    advance(demand, "schedule", scheduled_on: today.iso8601)
    result = advance(demand, "decline", text: "Endereço fora do município de atuação.")
    expect(result).to be_ok
    expect(demand.reload).to have_attributes(state: "closed", outcome: nil, version: 3)
    expect(forwarding_of(demand)).to have_attributes(state: "declined", reply: "Endereço fora do município de atuação.")
    expect(manifestation_of(demand).state).to eq("in_analysis")
    expect(refusal(advance(demand, "decline", text: "Fora da área de atuação."))).to eq([ :forwarding_changed, nil ])
  end

  it "decline com texto curto → path text; com outcome → path outcome" do
    expect(refusal(advance(demand, "decline", text: "curto"))).to eq([ :invalid_request, "text" ])
    expect(refusal(advance(demand, "decline", text: "Fora da área de atuação.", outcome: "resolved"))).to eq([ :invalid_request, "outcome" ])
    expect(demand.reload).to have_attributes(state: "open", version: 1)
  end

  it "extend duas vezes → already_extended; a demanda segue aberta" do
    due = forwarding_of(demand).due_on
    expect(advance(demand, "extend", reason: "Aguardando o caminhão de recolhimento.")).to be_ok
    expect(forwarding_of(demand)).to have_attributes(extended: true, due_on: due + OmbudsmanSetting.current.forwarding_extension_days,
                                                     state: "pending")
    expect(demand.reload).to have_attributes(state: "open", version: 2)
    expect(refusal(advance(demand, "extend", reason: "Aguardando de novo o caminhão."))).to eq([ :already_extended, nil ])
    expect(demand.reload.version).to eq(2)
    expect(DomainEvent.where(name: "zoonoses_demand.changed").pluck(:payload)).to eq([ { "zoonoses_demand_id" => demand.id } ])
  end

  it "versão velha → demand_changed; encaminhamento cancelado pelo 33 → forwarding_changed" do
    expect(refusal(advance(demand, "schedule", scheduled_on: today.iso8601, expected_version: 7))).to eq([ :demand_changed, nil ])
    expect(refusal(advance(demand, "schedule", scheduled_on: today.iso8601, expected_version: :omit)))
      .to eq([ :expected_version_required, "expected_version" ])
    expect(refusal(advance(demand, "schedule", scheduled_on: today.iso8601, expected_version: "1"))).to eq([ :invalid_request, "expected_version" ])

    version = demand.reload.version
    cancelled = Ombudsman::CancelForwarding.call(forwarding_id: demand.ombudsman_forwarding_id, expected_state: "pending", reason: nil,
                                                 by: ombudsman_staff!)
    expect(cancelled).to be_ok
    expect(refusal(advance(demand, "schedule", scheduled_on: today.iso8601, expected_version: version))).to eq([ :forwarding_changed, nil ])
  end

  it "fora da máquina de estados → 409 invalid_transition path status; datas fora → date_out_of_range" do
    expect(refusal(advance(demand, "schedule", scheduled_on: (today - 1).iso8601))).to eq([ :date_out_of_range, "scheduled_on" ])
    expect(refusal(advance(demand, "schedule", scheduled_on: "2026-02-30"))).to eq([ :invalid_request, "scheduled_on" ])
    expect(refusal(advance(demand, "inspect", inspected_on: (today + 1).iso8601, inspection_note: "Foco no entulho do quintal.")))
      .to eq([ :date_out_of_range, "inspected_on" ])
    expect(refusal(advance(demand, "inspect", inspected_on: today.iso8601, inspection_note: "a" * 9))).to eq([ :invalid_request, "inspection_note" ])
    expect(refusal(advance(demand, "inspect", inspected_on: today.iso8601, inspection_note: "a" * 2001)))
      .to eq([ :invalid_request, "inspection_note" ])
    expect(refusal(advance(demand, "schedule", scheduled_on: today.iso8601, patient_id: SecureRandom.uuid))).to eq([ :invalid_request, "patient_id" ])
    expect(refusal(advance(demand, "reopen"))).to eq([ :invalid_request, "action" ])

    expect(advance(demand, "inspect", inspected_on: today.iso8601, inspection_note: "Foco no entulho do quintal.")).to be_ok
    expect(refusal(advance(demand, "schedule", scheduled_on: today.iso8601))).to eq([ :invalid_transition, "status" ])
    expect(refusal(advance(demand, "inspect", inspected_on: today.iso8601, inspection_note: "Outra visita ao local.")))
      .to eq([ :invalid_transition, "status" ])
    expect(demand.reload).to have_attributes(state: "inspected", version: 2)
  end

  it "a equipe responde sem o papel ombudsman_responder; um respondente do 33 de outro setor não" do
    expect(Ombudsman::Access.responder?(team)).to be(false)
    other = responder!(department!)

    expect(refusal(advance(demand, "close", by: other, outcome: "resolved", text: closing))).to eq([ :missing_role, nil ])
    via = Ombudsman::ReplyForwarding.call(forwarding_id: demand.ombudsman_forwarding_id, expected_state: "pending", body: closing, by: other,
                                          via_zoonoses: true)
    expect(via.reason).to eq(:not_found)
    plain = Ombudsman::ReplyForwarding.call(forwarding_id: demand.ombudsman_forwarding_id, expected_state: "pending", body: closing, by: team)
    expect(plain.reason).to eq(:not_found)
    expect(forwarding_of(demand).state).to eq("pending")

    expect(advance(demand, "close", outcome: "referred", text: closing)).to be_ok
    expect(forwarding_of(demand)).to have_attributes(state: "replied", replied_by_user_id: team.id)
  end

  it "via_zoonoses num encaminhamento sem demanda (a um setor) → not_found mesmo para a equipe" do
    manifestation = manifestation_of(demand)
    department = department!
    responder!(department)
    forwarded = Ombudsman::Forward.call(manifestation_id: manifestation.id, expected_state: "forwarded", department_id: department.id,
                                        health_unit_id: nil, extract: "Extrato para o setor de obras da prefeitura.", by: ombudsman_staff!)
    expect(forwarded).to be_ok
    result = Ombudsman::DeclineForwarding.call(forwarding_id: forwarded.payload[:forwarding].id, expected_state: "pending",
                                               reason: "Não é da equipe do centro.", by: team, via_zoonoses: true)
    expect(result.reason).to eq(:not_found)
  end

  it "fora da equipe → missing_role, nada gravado" do
    stock_keeper = staff_with("estoque-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper")
    expect(refusal(advance(demand, "schedule", by: stock_keeper, scheduled_on: today.iso8601))).to eq([ :missing_role, nil ])
    expect(demand.reload.version).to eq(1)
  end

  it "trava na ordem manifestação → encaminhamento → demanda (a do 33)" do
    order = []
    allow(Ombudsman::Lock).to receive(:forwarding!).and_wrap_original { |m, id| order << :forwarding; m.call(id) }
    allow(ZoonosesDemand).to receive(:lock).and_wrap_original { |m, *args| order << :demand; m.call(*args) }
    expect(advance(demand, "schedule", scheduled_on: today.iso8601)).to be_ok
    expect(order.first(2)).to eq(%i[forwarding demand])
  end

  describe "o fim do encaminhamento pelo 33 fecha a demanda na mesma transação" do
    it "o respondente do 33 da UVZ recusa pelo inbox → demanda closed sem outcome" do
      responder = responder!(uvz)
      result = Ombudsman::DeclineForwarding.call(forwarding_id: demand.ombudsman_forwarding_id, expected_state: "pending",
                                                 reason: "Não é da competência desta unidade.", by: responder)
      expect(result).to be_ok
      expect(demand.reload).to have_attributes(state: "closed", outcome: nil, version: 2)
      expect(DomainEvent.where(name: "zoonoses_demand.changed").sole.payload).to eq("zoonoses_demand_id" => demand.id)
    end

    it "o respondente do 33 da UVZ responde pelo inbox → demanda closed sem outcome" do
      advance(demand, "inspect", inspected_on: today.iso8601, inspection_note: "Foco no entulho do quintal.")
      result = Ombudsman::ReplyForwarding.call(forwarding_id: demand.ombudsman_forwarding_id, expected_state: "pending", body: closing,
                                               by: responder!(uvz))
      expect(result).to be_ok
      expect(demand.reload).to have_attributes(state: "closed", outcome: nil, version: 3)
    end

    it "a ouvidoria cancela → demanda closed; depois o Q34 aceita novo encaminhamento, com outra demanda open" do
      manifestation = manifestation_of(demand)
      cancelled = Ombudsman::CancelForwarding.call(forwarding_id: demand.ombudsman_forwarding_id, expected_state: "pending",
                                                   reason: nil, by: ombudsman_staff!)
      expect(cancelled).to be_ok
      expect(demand.reload).to have_attributes(state: "closed", outcome: nil, version: 2)
      expect(manifestation.reload.state).to eq("in_analysis")

      again = Ombudsman::Forward.call(manifestation_id: manifestation.id, expected_state: "in_analysis", department_id: nil,
                                      health_unit_id: uvz.id, extract: manifestation.body, by: ombudsman_staff!, zoonoses: true)
      expect(again).to be_ok
      expect(again.payload[:demand]).to have_attributes(state: "open", version: 1)
      expect(ZoonosesDemand.joins(:ombudsman_forwarding)
                           .where(ombudsman_forwardings: { ombudsman_manifestation_id: manifestation.id })
                           .pluck(:state)).to contain_exactly("closed", "open")
    end

    it "o respondente do 33 da UVZ prorroga pelo inbox → a demanda sobe a versão e publica changed uma vez, como pelo centro" do
      due = forwarding_of(demand).due_on
      result = Ombudsman::ExtendForwarding.call(forwarding_id: demand.ombudsman_forwarding_id, expected_state: "pending",
                                                reason: "Aguardando o caminhão de recolhimento.", by: responder!(uvz))
      expect(result).to be_ok
      expect(forwarding_of(demand)).to have_attributes(extended: true, due_on: due + OmbudsmanSetting.current.forwarding_extension_days)
      expect(demand.reload).to have_attributes(state: "open", version: 2)
      expect(DomainEvent.where(name: "zoonoses_demand.changed").pluck(:payload)).to eq([ { "zoonoses_demand_id" => demand.id } ])
      expect(refusal(advance(demand, "extend", reason: "Aguardando de novo o caminhão."))).to eq([ :already_extended, nil ])
    end
  end

  # Regra do controlador e Q34: recusado o encaminhamento (pelo centro ou
  # pelo inbox do 33), a demanda fecha e um novo encaminhamento à mesma UVZ
  # cria outra: uma demanda aberta por vez na manifestação.
  describe "recusa seguida de novo encaminhamento → exatamente uma demanda aberta" do
    def forward_again(manifestation)
      Ombudsman::Forward.call(manifestation_id: manifestation.id, expected_state: manifestation.reload.state, department_id: nil,
                              health_unit_id: uvz.id, extract: manifestation.body, by: ombudsman_staff!, zoonoses: true)
    end

    def states_of(manifestation)
      ZoonosesDemand.joins(:ombudsman_forwarding).where(ombudsman_forwardings: { ombudsman_manifestation_id: manifestation.id })
                    .order(:created_at).pluck(:state)
    end

    it "recusa pelo centro (AdvanceDemand decline)" do
      manifestation = manifestation_of(demand)
      expect(advance(demand, "decline", text: "Endereço fora da área de atuação.")).to be_ok
      expect(forward_again(manifestation)).to be_ok
      expect(states_of(manifestation)).to eq(%w[closed open])
    end

    it "recusa pelo inbox do 33 (DeclineForwarding do respondente da UVZ)" do
      manifestation = manifestation_of(demand)
      declined = Ombudsman::DeclineForwarding.call(forwarding_id: demand.ombudsman_forwarding_id, expected_state: "pending",
                                                   reason: "Não é da competência desta unidade.", by: responder!(uvz))
      expect(declined).to be_ok
      expect(forward_again(manifestation)).to be_ok
      expect(states_of(manifestation)).to eq(%w[closed open])
    end
  end
end
