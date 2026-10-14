require "rails_helper"

# Spec §4 "Ligação com o 19a": finalizar cria um exam_order por pedido
# requested, na mesma transação; o adendo que cancela o pedido cancela o
# exame (se ainda sem resultado). Desligado: nada muda.
RSpec.describe Exams::FromConsultation do
  before { exam_city! }

  let(:unit) { create_unit("UBS Consulta") }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(40) }

  it "a finalização cria o exame com prioridade, solicitante, unidade e competência" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen,
                                           exam_requests: [ { "sigtap_code" => "0202010503", "priority" => "urgent" } ])
    request = consultation.exam_requests.first
    order = ExamOrder.find_by!(consultation_exam_request_id: request.id)
    expect(request.priority).to eq("urgent")
    expect(order).to have_attributes(origin: "consultation", priority: "urgent", requester_user_id: doctor.id, unit_id: unit.id,
                                     patient_id: consultation.patient_id, sigtap_competence: request.sigtap_competence,
                                     status: "awaiting_schedule")
  end

  it "exame fora do catálogo da cidade vira exame com os padrões (Desvio 8)" do
    expect(ExamCatalogItem.find_by(sigtap_code: "0202010503")).to be_nil
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    expect(ExamOrder.find_by!(patient_id: consultation.patient_id)).to have_attributes(status: "awaiting_schedule", priority: "routine")
  end

  it "exame que exige autorização nasce aguardando autorização" do
    exam_catalog_item!(requires_authorization: true)
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    expect(ExamOrder.find_by!(patient_id: consultation.patient_id).status).to eq("awaiting_authorization")
  end

  it "prioridade inválida recusa o rascunho com o índice" do
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    saved = Consultations::SaveDraft.call(consultation: consultation, by: doctor,
                                          params: draft_body(exam_requests: [ { "sigtap_code" => "0202010503", "priority" => "now" } ]))
    expect([ saved.reason, saved.details ]).to eq([ :invalid_exam, { index: 0 } ])
  end

  it "a leitura da consulta devolve a prioridade, em rascunho e finalizada (A26)" do
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    Consultations::SaveDraft.call(consultation: consultation, by: doctor,
                                  params: draft_body(exam_requests: [ { "sigtap_code" => "0202010503", "priority" => "urgent" } ]))
    expect(Consultations::Json.consultation(consultation.reload)[:exam_requests].first[:priority]).to eq("urgent")
    Consultations::Finalize.call(consultation: consultation, outcome_params: { "outcome" => "discharged" }, by: doctor)
    expect(Consultations::Json.consultation(consultation.reload)[:exam_requests].first[:priority]).to eq("urgent")
  end

  it "o adendo que tira o exame cancela o exam_order; com resultado, não" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    order = ExamOrder.find_by!(patient_id: consultation.patient_id)
    result = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "exame já feito em outro serviço",
                                             text: "Exame retirado", changes: { "exam_requests" => [] })
    expect(result).to be_ok
    expect(order.reload.status).to eq("cancelled")
    expect(order.events.last).to have_attributes(kind: "cancelled", actor_user_id: doctor.id)
  end

  it "o adendo não cancela exame que já tem resultado" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    order = ExamOrder.find_by!(patient_id: consultation.patient_id)
    order.update_columns(status: "resulted") # estado após resultado; o gatilho de guarda é por evento, não por coluna
    Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "exame já feito em outro serviço",
                                    text: "Exame retirado", changes: { "exam_requests" => [] })
    expect(order.reload.status).to eq("resulted")
  end

  it "o adendo que acrescenta exame abre um exam_order novo" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    result = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "esqueci um exame",
                                             text: "Mais um exame",
                                             changes: { "exam_requests" => [ { "sigtap_code" => "0202010503" },
                                                                             { "sigtap_code" => "0202010317", "priority" => "urgent" } ] })
    expect(result).to be_ok
    expect(ExamOrder.where(patient_id: consultation.patient_id).count).to eq(2)
    expect(ExamOrder.where(sigtap_code: "0202010317").first.priority).to eq("urgent")
  end

  it "com exam_tracking desligado a consulta segue como no 19a (Regressão)" do
    Platform::Features.set!(city: Current.city, key: "exam_tracking", enabled: false, maintainer: ledi_maintainer!)
    finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    expect(ExamOrder.count).to eq(0)
  end
end
