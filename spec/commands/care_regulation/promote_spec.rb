require "rails_helper"

# Módulo 26a, Task 5 (ADR 0044; contrato §3, §13 G1, G4, G12 #3–#5): os
# rascunhos de regulação valem na finalização e no adendo; "encaminhado" sem
# unidade passa pela regulação; o rascunho que deixou de valer fica em draft e
# volta no regulation_not_sent, sem travar a finalização nem o adendo.
RSpec.describe "Promoção dos pedidos de regulação (consulta e adendo)" do
  include ActiveSupport::Testing::TimeHelpers

  before { regulation_city! }
  let(:unit) { HealthUnit.create!(name: "UBS Promove #{SecureRandom.hex(2)}", kind: "ubs") }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(11) }
  let(:attrs) { { "type" => "specialty", "target_code" => "225120", "cid10" => "I10",
                  "justification" => "Hipertensão resistente a três fármacos", "suggested_color" => "yellow" } }

  def draft!(consultation, by: doctor, **over)
    CareRegulation::SaveDraft.call(consultation: consultation, attrs: attrs.merge(over.transform_keys(&:to_s)), by: by).payload.fetch(:request)
  end

  # Designação a outro profissional pelo caminho real (o trigger da consulta
  # recusa trocar autora e CBO por update_columns).
  def reassign!(consultation, user)
    result = ConsultationDrafts::Reassign.call(consultation_id: consultation.id, user_id: user.id, reason: "Profissional saiu da unidade",
                                               by: staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin"))
    raise "designação recusada: #{result.reason}" if result.failure?

    consultation.reload
  end

  def finalize!(consultation, outcome: { "outcome" => "referred" }, by: doctor)
    Consultations::SaveDraft.call(consultation: consultation, params: draft_body, by: by)
    Consultations::Finalize.call(consultation: consultation.reload, outcome_params: outcome, by: by)
  end

  it "finalizar com 'encaminhado' sem unidade promove o rascunho e não abre o referral do 17" do
    travel_to Time.zone.parse("2026-10-28 10:00") do
      consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
      request = draft!(consultation)
      result = finalize!(consultation)
      expect(result).to be_ok
      expect(request.reload).to have_attributes(status: "pending", due_on: Date.new(2026, 11, 27), requester_user_id: doctor.id,
                                                requester_cbo: "225125", requested_at: Time.current, version: 2)
      expect(request.events.map(&:status)).to eq([ "pending" ])
      expect(request.events.sole.by_user_id).to eq(doctor.id)
      expect(result.payload[:appointment_request]).to be_nil
      expect(result.payload[:regulation_not_sent]).to eq([])
      expect(consultation.attendance.reload).to have_attributes(outcome: "referred", referral_regulated: true, referral_note: nil,
                                                                referral_unit_id: nil)
      expect(DomainEvent.where(name: "regulation_request.created").last.payload).to eq("regulation_request_id" => request.id, "user_id" => doctor.id)
    end
  end

  it "'encaminhado' sem unidade e sem pedido, com o interruptor ligado → regulation_request_required; com unidade, o referral de hoje" do
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    expect(finalize!(consultation, outcome: { "outcome" => "referred", "referral_note" => "Cardiologia" }).reason).to eq(:regulation_request_required)
    expect(consultation.reload.status).to eq("draft")
    other = HealthUnit.create!(name: "UBS Destino #{SecureRandom.hex(2)}", kind: "ubs")
    result = finalize!(consultation.reload, outcome: { "outcome" => "referred", "referral_unit_id" => other.id })
    expect(result.payload[:appointment_request].kind).to eq("referral")
    expect(result.payload[:attendance]).to have_attributes(referral_unit_id: other.id, referral_regulated: false)
  end

  it "falha do Close desfaz a promoção junto com a finalização (unidade de encaminhamento inexistente)" do
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    request = draft!(consultation)
    result = finalize!(consultation, outcome: { "outcome" => "referred", "referral_unit_id" => SecureRandom.uuid })
    expect(result.reason).to eq(:invalid_unit)
    expect(consultation.reload.status).to eq("draft")
    expect(request.reload).to have_attributes(status: "draft", version: 1, requested_at: nil)
    expect(request.events).to be_empty
    expect(DomainEvent.where(name: "regulation_request.created")).to be_empty
  end

  it "regulado pelo estado nasce external, fora da fila" do
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    request = draft!(consultation, state_regulated: true)
    finalize!(consultation, outcome: { "outcome" => "discharged" })
    expect(request.reload).to have_attributes(status: "external", state_regulated: true)
    expect(request.due_on).to be_present
    expect(request.events.map(&:status)).to eq([ "external" ])
    expect(DomainEvent.where(name: "regulation_request.created").last.payload).to eq("regulation_request_id" => request.id, "user_id" => doctor.id)
    expect(DomainEvent.where(name: "regulation_request.external")).to be_empty
  end

  it "adendo promove rascunho criado depois da finalização" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    request = draft!(consultation)
    result = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "Pedido de cardiologia esquecido",
                                             text: "Acrescento encaminhamento à cardiologia.")
    expect(result).to be_ok
    expect(request.reload).to have_attributes(status: "pending", addendum_id: result.payload[:addendum].id)
    expect(result.payload[:regulation_not_sent]).to eq([])
  end

  it "adendo nunca falha por rascunho inválido: o item saiu da lista do enfermeiro, o rascunho fica draft e aparece com index" do
    admin = staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin")
    nurse = screener!(unit, cbo: "223505")
    consultation = finalized_consultation!(unit: unit, doctor: nurse, citizen: citizen)
    CareRegulation::NurseItems.add(target_type: "specialty", target_code: "225120", by: admin)
    request = draft!(consultation, by: nurse, cid10: nil, ciap2: "K86")
    CareRegulation::NurseItems.remove(target_type: "specialty", target_code: "225120", by: admin)
    result = Consultations::AddAddendum.call(consultation: consultation, by: nurse, reason: "Pedido de cardiologia esquecido",
                                             text: "Acrescento encaminhamento à cardiologia.")
    expect(result).to be_ok
    expect(result.payload[:regulation_not_sent]).to eq([ { index: 0, id: request.id, error: "cbo_not_allowed", path: "target_code" } ])
    expect(request.reload).to have_attributes(status: "draft", version: 1, addendum_id: nil)
    expect(DomainEvent.where(name: "regulation_request.created")).to be_empty
  end

  it "Review Focus 5: consulta designada à enfermeira finaliza; o pedido fora da lista fica draft com index; descartada apaga o rascunho" do
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    request = draft!(consultation)
    nurse = screener!(unit, cbo: "223505")
    reassign!(consultation, nurse)
    result = finalize!(consultation.reload, outcome: { "outcome" => "discharged" }, by: nurse)
    expect(result).to be_ok
    expect(consultation.reload.status).to eq("finalized")
    expect(result.payload[:regulation_not_sent]).to eq([ { index: 0, id: request.id, error: "cbo_not_allowed", path: "target_code" } ])
    expect(request.reload).to have_attributes(status: "draft", version: 1)
    expect(DomainEvent.where(name: "regulation_request.created")).to be_empty
    other = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(12))
    orphan = draft!(other)
    ConsultationDrafts::Discard.call(consultation_id: other.id, reason: "Rascunho órfão da médica",
                                     by: staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin"))
    expect(RegulationRequest.exists?(orphan.id)).to be(false)
  end

  it "válido e inválido na mesma finalização: um vai, o outro fica com index 1" do
    admin = staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin")
    CareRegulation::NurseItems.add(target_type: "specialty", target_code: "225120", by: admin)
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    ok = draft!(consultation)                              # 225120, da lista do enfermeiro
    ok.update!(cid10: nil, ciap2: "K86")                   # o diagnóstico que vale para a enfermeira
    bad = draft!(consultation, target_code: "225250")      # fora da lista
    nurse = screener!(unit, cbo: "223505")
    reassign!(consultation, nurse)
    result = finalize!(consultation.reload, outcome: { "outcome" => "discharged" }, by: nurse)
    expect(result).to be_ok
    expect(ok.reload).to have_attributes(status: "pending", requester_user_id: nurse.id, requester_cbo: "223505")
    expect(result.payload[:regulation_not_sent]).to eq([ { index: 1, id: bad.id, error: "cbo_not_allowed", path: "target_code" } ])
    expect(bad.reload.status).to eq("draft")
  end

  it "diagnóstico que deixou de valer (G10): o rascunho do médico sem CID-10 válido para a enfermeira fica com o path do diagnóstico" do
    admin = staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin")
    CareRegulation::NurseItems.add(target_type: "specialty", target_code: "225120", by: admin)
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    request = draft!(consultation)                         # cid10 I10, da médica
    nurse = screener!(unit, cbo: "223505")
    reassign!(consultation, nurse)
    result = finalize!(consultation.reload, outcome: { "outcome" => "referred" }, by: nurse)
    expect(result).to be_ok
    expect(result.payload[:regulation_not_sent]).to eq([ { index: 0, id: request.id, error: "cid10_not_allowed_for_cbo", path: "cid10" } ])
    expect(consultation.attendance.reload.outcome).to eq("referred") # G12 #4: o rascunho presente conta
  end

  it "interruptor desligado: o rascunho fica rascunho e o 'encaminhado' segue a regra de hoje" do
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    request = draft!(consultation)
    Platform::Features.set!(city: Current.city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
    result = finalize!(consultation, outcome: { "outcome" => "referred", "referral_note" => "Cardiologia" })
    expect(result).to be_ok
    expect(result.payload).not_to have_key(:regulation_not_sent)
    expect(request.reload.status).to eq("draft")
    expect(consultation.attendance.reload).to have_attributes(referral_note: "Cardiologia", referral_regulated: false)
  end

  describe "CareRegulation::Transition" do
    let(:request) { regulation_request! }

    it "grava situação, versão, andamento e publica só ids; versão velha → stale_version" do
      result = CareRegulation::Transition.call(request: request.lock!, to: "returned", by: doctor, reason: "Falta o exame de base",
                                               version: request.version)
      expect(result).to be_ok
      expect(request.reload).to have_attributes(status: "returned", version: 3)
      expect(request.events.last).to have_attributes(status: "returned", by_user_id: doctor.id)
      expect(DomainEvent.where(name: "regulation_request.returned").last.payload)
        .to eq("regulation_request_id" => request.id, "user_id" => doctor.id)
      expect(CareRegulation::Transition.call(request: request.lock!, to: "pending", by: doctor, version: 2).reason).to eq(:stale_version)
      expect(request.reload.status).to eq("returned")
    end

    it "pending do complemento publica complemented; sem autor, user_id nulo; publish: false não publica" do
      CareRegulation::Transition.call(request: request.lock!, to: "returned", by: doctor, reason: "Falta o exame de base")
      CareRegulation::Transition.call(request: request.lock!, to: "pending", by: nil, event: "complemented")
      expect(DomainEvent.where(name: "regulation_request.complemented").last.payload)
        .to eq("regulation_request_id" => request.id, "user_id" => nil)
      expect { CareRegulation::Transition.call(request: request.lock!, to: "returned", by: doctor, publish: false) }
        .not_to(change { DomainEvent.where(name: "regulation_request.returned").count })
      expect(request.reload.events.map(&:status)).to eq(%w[pending returned pending returned])
    end

    it "G1: missed nunca é situação atual; record_event! só grava o andamento e publica" do
      expect { CareRegulation::Transition.call(request: request.lock!, to: "missed", by: doctor) }.to raise_error(ArgumentError)
      version = request.reload.version
      CareRegulation::Transition.record_event!(request: request, status: "missed", by: nil)
      expect(request.reload).to have_attributes(status: "pending", version: version)
      expect(request.events.last.status).to eq("missed")
      expect(DomainEvent.where(name: "regulation_request.missed").last.payload)
        .to eq("regulation_request_id" => request.id, "user_id" => nil)
    end
  end
end
