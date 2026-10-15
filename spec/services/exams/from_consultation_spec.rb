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
    expect(order.events.pluck(:kind)).not_to include("cancelled")
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

  it "falha ao abrir o exame desfaz a finalização inteira (propaga o motivo)" do
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    Consultations::SaveDraft.call(consultation: consultation, by: doctor, params: draft_body)
    allow(Exams::Open).to receive(:call).and_return(Result.fail(:invalid_priority))
    expect { Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: doctor) }
      .to raise_error(Exams::FromConsultation::OpenFailed, /invalid_priority/)
    expect(consultation.reload).to be_draft
    expect(ConsultationExamRequest.count).to eq(0)
    expect(ExamOrder.count).to eq(0)
  end

  it "falha ao cancelar o exame desfaz o adendo" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    allow(Exams::Transition).to receive(:call).and_return(Result.fail(:invalid_transition))
    expect do
      Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "exame já feito em outro serviço",
                                      text: "Exame retirado", changes: { "exam_requests" => [] })
    end.to raise_error(RuntimeError, /invalid_transition/)
    expect(ConsultationAddendum.count).to eq(0)
    expect(consultation.exam_requests.where(status: "cancelled").count).to eq(0)
  end

  it "adendo que só muda a prioridade não altera o exame (prioridade fixa na criação)" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    order = ExamOrder.find_by!(patient_id: consultation.patient_id)
    Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "mudar prioridade", text: "Urgente",
                                    changes: { "exam_requests" => [ { "sigtap_code" => "0202010503", "priority" => "urgent" } ] })
    expect(ExamOrder.where(patient_id: consultation.patient_id).count).to eq(1)
    expect(order.reload).to have_attributes(priority: "routine", status: "awaiting_schedule")
    expect(order.events.pluck(:kind)).not_to include("cancelled")
  end

  context "com o exame numa requisição do laboratório" do
    before { lab_city! }

    let(:provider) { lab_provider! }
    let(:consultation) do
      lab_exam!(provider: provider)
      finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen,
                              exam_requests: [ { "sigtap_code" => "0202010473", "priority" => "routine" } ])
    end
    let(:order) { ExamOrder.find_by!(patient_id: consultation.patient_id) }

    def open_for(order)
      result = Lab::OpenRequisition.call({ patient_id: order.patient_id, provider_id: provider.id, origin_unit_id: unit.id,
                                           collection_place: "lab", biological_sex: "female", mother_name: "Joana",
                                           exam_order_ids: [ order.id ] }, by: lab_staff!)
      result.payload[:requisition]
    end

    def retract
      Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "exame retirado do plano",
                                      text: "Exame retirado", changes: { "exam_requests" => [] })
    end

    it "o adendo cancela o item pendente junto com o exame" do
      req = open_for(order)
      expect(retract).to be_ok
      expect(order.reload.status).to eq("cancelled")
      expect(req.items.first.reload.status).to eq("cancelled")
    end

    it "item digitado: o exame fica como está e o adendo segue" do
      req = open_for(order)
      req.items.first.update!(status: "typed")
      expect(retract).to be_ok
      expect(order.reload.status).to eq("scheduled")
      expect(req.items.first.reload.status).to eq("typed")
    end
  end
end
