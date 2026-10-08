# spec/commands/consultations/finalize_spec.rb
require "rails_helper"

# ADR 0031 (spec §4, §8): finalizar exige problema avaliado, conduta, A ou P,
# nome do paciente e CID-10 permitido; numa transação aplica os eventos de
# problema, grava os itens, vira finalized e fecha o atendimento com o
# desfecho (retorno/encaminhamento geram o pedido). Review Focus 4.
RSpec.describe Consultations::Finalize do
  before { Current.city = clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  def draft!(**over) = Consultations::SaveDraft.call(consultation: consultation, params: draft_body(**over), by: doctor)

  def finalize(outcome = { "outcome" => "discharged" }, by: doctor)
    described_class.call(consultation: consultation.reload, outcome_params: outcome, by: by)
  end

  it "finaliza: itens, problema com evento da consulta, atendimento fechado; eventos só com ids" do
    draft!
    result = finalize
    expect(result).to be_ok
    consultation.reload
    expect(consultation).to have_attributes(status: "finalized", draft_items: {})
    expect(consultation.finalized_at).to be_present
    problem = PatientProblem.where(patient_id: consultation.patient_id).sole
    expect(problem).to have_attributes(code: "T90", status: "active", onset_on: Date.new(2025, 8, 1), onset_precision: "month")
    expect(problem.events.sole).to have_attributes(kind: "added", consultation_id: consultation.id)
    expect(consultation.problem_items.sole).to have_attributes(patient_problem_id: problem.id, action: "add", status_after: "active")
    expect(consultation.conducts.pluck(:code)).to eq([ 1 ])
    expect(consultation.exam_requests.sole).to have_attributes(sigtap_code: "0202010503", status: "requested")
    expect(consultation.attendance.reload).to have_attributes(status: "closed", outcome: "discharged", closed_by_user_id: doctor.id)
    expect(DomainEvent.where(name: "consultation.finalized").sole.payload)
      .to eq("consultation_id" => consultation.id, "attendance_id" => consultation.attendance_id)
  end

  it "retorno gera o pedido do módulo 17 na mesma transação" do
    draft!
    result = finalize({ "outcome" => "return" })
    expect(result).to be_ok
    expect(result.payload[:appointment_request]).to have_attributes(kind: "return", origin_attendance_id: consultation.attendance_id)
  end

  {
    { "evaluated_problems" => [] } => :no_problem_evaluated,
    { "conducts" => [] } => :no_conduct,
    { "assessment" => "", "plan" => " " } => :assessment_or_plan_required,
    { "care_type" => nil } => :invalid_care_type
  }.each do |over, reason|
    it("#{over.inspect} → #{reason}") do
      draft!(**over.transform_keys(&:to_sym))
      expect(finalize.reason).to eq(reason)
      expect(consultation.reload.status).to eq("draft")
    end
  end

  it "paciente sem nome → patient_name_missing; CID-10 que a regra recusa → cid10_not_allowed_for_cbo" do
    draft!
    consultation.patient.update_columns(full_name: nil)
    expect(finalize.reason).to eq(:patient_name_missing)
    consultation.patient.update_columns(full_name: "Maria Aparecida da Silva")
    draft!(evaluated_problems: [ { "terminology" => "cid10", "code" => "E119", "action" => "add" } ])
    allow(Ledi::ConsultationMapping).to receive(:cid10_allowed?).and_return(false)
    result = finalize
    expect([ result.reason, result.details ]).to eq([ :cid10_not_allowed_for_cbo, { index: 0 } ])
  end

  it "só o autor; finalizada não finaliza de novo" do
    draft!
    expect(finalize(by: doctor!(unit, cbo: "223505")).reason).to eq(:not_author)
    expect(finalize).to be_ok
    expect(finalize.reason).to eq(:not_draft)
  end

  it "falha do desfecho desfaz tudo: nada de item, problema, evento ou atendimento fechado (Review Focus 4)" do
    draft!
    inactive = create_unit("UPA Norte", kind: "upa", active: false)
    result = finalize({ "outcome" => "referred", "referral_unit_id" => inactive.id })
    expect(result.reason).to eq(:invalid_unit)
    expect(consultation.reload).to have_attributes(status: "draft")
    expect([ ConsultationProblem.count, ConsultationConduct.count, PatientProblem.count, PatientProblemEvent.count ]).to eq([ 0, 0, 0, 0 ])
    expect(DomainEvent.where(name: %w[consultation.finalized patient_problem.changed attendance.closed]).count).to eq(0)
    expect(consultation.attendance.reload.status).to eq("in_care")
    expect(finalize({ "outcome" => "oriented" }).reason).to eq(:invalid_outcome)
    expect(consultation.reload.status).to eq("draft")
  end

  it "problema resolvido por outra consulta entre o rascunho e a finalização → invalid_problem, nada muda" do
    draft!
    finalize
    problem = PatientProblem.sole
    second = started_consultation!(unit: unit, doctor: doctor, citizen: consultation.attendance.citizen.reload)
    Consultations::SaveDraft.call(consultation: second, by: doctor,
                                  params: draft_body(evaluated_problems: [ { "problem_id" => problem.id, "action" => "resolve" } ]))
    ApplicationRecord.transaction do
      Patients::ApplyProblemEvent.call(patient: problem.patient, action: "resolve", problem: problem, by: doctor,
                                       source: { consultation: consultation })
    end
    result = described_class.call(consultation: second.reload, outcome_params: { "outcome" => "discharged" }, by: doctor)
    expect([ result.reason, result.details ]).to eq([ :invalid_problem, { index: 0 } ])
    expect(second.reload.status).to eq("draft")
  end

  it "rascunho aberto bloqueia a rota antiga de desfecho (Review Focus 4)" do
    draft!
    result = Attendances::Close.call(attendance: consultation.attendance, outcome: "discharged", referral_unit_id: nil,
                                     referral_note: nil, by: doctor)
    expect(result.reason).to eq(:consultation_in_progress)
    expect(consultation.attendance.reload.status).to eq("in_care")
  end

  it "estado efetivo: última linha de cada problema, condutas e exames" do
    draft!(conducts: [ 1, 9 ])
    finalize
    effective = Consultations::Effective.call(consultation.reload)
    expect(effective[:problems].map(&:code)).to eq([ "T90" ])
    expect(effective[:conducts]).to eq([ 1, 9 ])
    expect(effective[:exam_requests].map(&:sigtap_code)).to eq([ "0202010503" ])
  end

  # Decisão do usuário 2026-10-08: a ficha de não médico omite os problemas
  # CID-10 e o layout exige ao menos um problemasCondicoes (dicionario-fai.html
  # #28, mínimo 1) — sem CIAP-2 avaliado, a ficha sairia vazia.
  describe "não médico precisa de ao menos um CIAP-2 avaliado" do
    let(:nurse) { doctor!(unit, cbo: "223505") }

    # Médico deixa E119 (CID-10) na lista; o enfermeiro só pode avaliá-lo.
    def nurse_consultation!(problems)
      finalized_consultation!(unit: unit, doctor: doctor, citizen: consultation.attendance.citizen,
                              evaluated_problems: [ { "terminology" => "cid10", "code" => "E119", "action" => "add" } ])
      nursing = started_consultation!(unit: unit, doctor: nurse, citizen: consultation.attendance.citizen.reload)
      cid10 = PatientProblem.find_by!(code: "E119")
      list = problems.map { |kind| kind == :cid10 ? { "problem_id" => cid10.id, "action" => "evaluate" } : { "terminology" => "ciap2", "code" => "T90", "action" => "add" } }
      saved = Consultations::SaveDraft.call(consultation: nursing, params: draft_body(evaluated_problems: list), by: nurse)
      raise "rascunho recusado: #{saved.reason}" if saved.failure?

      nursing.reload
    end

    it "enfermeiro só com CID-10 avaliado → ciap2_required_for_cbo, nada muda" do
      nursing = nurse_consultation!([ :cid10 ])
      result = described_class.call(consultation: nursing, outcome_params: { "outcome" => "discharged" }, by: nurse)
      expect(result.reason).to eq(:ciap2_required_for_cbo)
      expect(nursing.reload.status).to eq("draft")
      expect(nursing.attendance.reload.status).to eq("in_care")
      expect(ConsultationProblem.where(consultation_id: nursing.id).count).to eq(0)
    end

    it "enfermeiro com CID-10 e CIAP-2 avaliados → ok" do
      nursing = nurse_consultation!([ :cid10, :ciap2 ])
      result = described_class.call(consultation: nursing, outcome_params: { "outcome" => "discharged" }, by: nurse)
      expect(result).to be_ok
      expect(nursing.reload.problem_items.map(&:code)).to contain_exactly("E119", "T90")
    end

    it "médico só com CID-10 → ok" do
      draft!(evaluated_problems: [ { "terminology" => "cid10", "code" => "E119", "action" => "add" } ])
      expect(finalize).to be_ok
    end
  end
end
