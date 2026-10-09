require "rails_helper"

# ADR 0031 (spec §4): adendo só em consulta finalizada, com motivo de 10+,
# texto cifrado; só da autora (decisão do usuário 2026-10-09: terceiro →
# not_author, mesmo com abertura; o opening_id do corpo é ignorado no
# controller); pode mudar
# problemas, condutas e exames (eventos com o adendo).
RSpec.describe Consultations::AddAddendum do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  def add(by: doctor, reason: "correção do pedido de exame", text: "Texto do adendo", **args)
    described_class.call(consultation: consultation, by: by, reason: reason, text: text, **args)
  end

  def opening_for(user, patient: consultation.patient, at: Time.current)
    ClinicalRecordOpening.create!(patient: patient, user: user, reason_code: "case_review", created_at: at, expires_at: at + 30.minutes)
  end

  it "o autor acrescenta texto e motivo; evento só com ids; sem mudança estruturada" do
    result = add(text: "MARCADOR-ADENDO")
    addendum = result.payload[:addendum]
    expect([ addendum.text, addendum.reason, addendum.item_changes, result.payload[:structured] ])
      .to eq([ "MARCADOR-ADENDO", "correção do pedido de exame", {}, false ])
    expect(DomainEvent.where(name: "consultation.addendum_added").sole.payload)
      .to eq("consultation_id" => consultation.id, "addendum_id" => addendum.id)
    expect(DomainEvent.pluck(:payload).to_json).not_to include("MARCADOR")
  end

  it "recusas de entrada e de estado" do
    { { reason: "curto" } => :invalid_reason, { reason: [ "x" * 20 ] } => :invalid_reason, { text: " " } => :text_required,
      { text: "x" * 20_001 } => :text_too_long, { changes: { "apagar" => [] } } => :invalid_changes,
      { changes: "lixo" } => :invalid_changes }.each do |args, reason|
      expect(add(**args).reason).to eq(reason), args.inspect
    end
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
    expect(described_class.call(consultation: draft, by: doctor, reason: "motivo suficiente", text: "x").reason).to eq(:not_finalized)
  end

  it "só a autora: terceiro → not_author mesmo com abertura válida e antes de validar a entrada; recepção missing_role" do
    nurse = doctor!(unit, cbo: "223505")
    expect(add(by: nurse).reason).to eq(:not_author)
    opening_for(nurse)
    expect(add(by: nurse).reason).to eq(:not_author)
    expect(add(by: nurse, reason: "curto", text: " ").reason).to eq(:not_author)
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
    expect(described_class.call(consultation: draft, by: nurse, reason: "motivo suficiente", text: "x").reason).to eq(:not_author)
    expect(add(by: reception!).reason).to eq(:missing_role)
    expect(ConsultationAddendum.count).to eq(0)
  end

  it "condutas e exames removidos viram linhas remove/cancelled ligadas ao adendo; o efetivo os tira" do
    addendum = add(changes: { "conducts" => [ 9 ], "exam_requests" => [] }).payload[:addendum]
    expect(consultation.conducts.where(addendum: addendum).pluck(:code, :action)).to match_array([ [ 9, "add" ], [ 1, "remove" ] ])
    expect(consultation.exam_requests.where(addendum: addendum).pluck(:sigtap_code, :status)).to eq([ [ "0202010503", "cancelled" ] ])
    effective = Consultations::Effective.call(consultation.reload)
    expect([ effective[:conducts], effective[:exam_requests] ]).to eq([ [ 9 ], [] ])
    back = add(changes: { "conducts" => [ 1, 9 ], "exam_requests" => [ { "sigtap_code" => "0202010503" } ] })
    effective = Consultations::Effective.call(consultation.reload)
    expect(effective[:conducts]).to eq([ 9, 1 ])
    expect(effective[:exam_requests].sole).to have_attributes(sigtap_code: "0202010503", addendum_id: back.payload[:addendum].id)
  end

  it "falha ao aplicar o evento de problema depois de gravar o adendo: nada fica, com o index" do
    problem = PatientProblem.where(patient_id: consultation.patient_id).sole
    allow(Patients::ApplyProblemEvent).to receive(:call).and_return(Result.fail(:invalid_problem))
    result = add(changes: { "evaluated_problems" => [ { "problem_id" => problem.id, "action" => "resolve" } ],
                            "conducts" => [ 9 ] })
    expect([ result.reason, result.details ]).to eq([ :invalid_problem, { index: 0 } ])
    expect([ ConsultationAddendum.count, consultation.conducts.where.not(addendum_id: nil).count ]).to eq([ 0, 0 ])
    expect(DomainEvent.where(name: "consultation.addendum_added")).to be_empty
  end

  it "autora não médica avalia CID-10 existente mas não acrescenta CID-10 nem justifica exame com CID-10" do
    citizen = verified_citizen!(1)
    finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen,
                            evaluated_problems: [ { "terminology" => "cid10", "code" => "E119", "action" => "add" } ])
    nurse = doctor!(unit, cbo: "223505")
    nursing = finalized_consultation!(unit: unit, doctor: nurse, citizen: citizen.reload, exam_requests: [])
    add_nursing = ->(changes) { described_class.call(consultation: nursing, by: nurse, reason: "acréscimo de dados", text: "x", changes: changes) }
    cid = { "evaluated_problems" => [ { "terminology" => "cid10", "code" => "I10", "action" => "add" } ] }
    expect(add_nursing.(cid).reason).to eq(:cid10_not_allowed_for_cbo)
    exam = { "exam_requests" => [ { "sigtap_code" => "0202010503", "cid10_justification" => "E119" } ] }
    expect(add_nursing.(exam).reason).to eq(:cid10_not_allowed_for_cbo)
    expect(ConsultationAddendum.count).to eq(0)
    existing = PatientProblem.find_by!(code: "E119")
    expect(add_nursing.({ "evaluated_problems" => [ { "problem_id" => existing.id, "action" => "evaluate" } ] })).to be_ok
  end

  it "evaluated_problems são eventos novos; conducts e exam_requests são as listas finais; o efetivo reflete" do
    problem = PatientProblem.where(patient_id: consultation.patient_id).sole
    result = add(changes: { "evaluated_problems" => [ { "problem_id" => problem.id, "action" => "resolve" },
                                                      { "terminology" => "cid10", "code" => "I10", "action" => "add" } ],
                            "conducts" => [ 9 ],
                            "exam_requests" => [ { "sigtap_code" => "0202010317" } ] })
    expect(result.payload[:structured]).to be(true)
    addendum = result.payload[:addendum]
    expect(problem.reload).to have_attributes(status: "resolved", resolved_on: Time.zone.today)
    expect(problem.events.order(:created_at).last).to have_attributes(kind: "resolved", addendum_id: addendum.id)
    effective = Consultations::Effective.call(consultation.reload)
    expect(effective[:conducts]).to eq([ 9 ])
    expect(effective[:exam_requests].map(&:sigtap_code)).to eq([ "0202010317" ])
    expect(effective[:problems].map { |p| [ p.code, p.status_after ] }).to match_array([ [ "T90", "resolved" ], [ "I10", "active" ] ])
    expect(addendum.item_changes.keys).to match_array(%w[evaluated_problems conducts exam_requests])
    expect(addendum.item_changes["conducts"]).to eq([ 9 ])
  end

  it "lista final igual à atual não entra em changes; trocar a justificativa do exame recancela e repede" do
    same = add(changes: { "conducts" => [ 1 ], "exam_requests" => [ { "sigtap_code" => "0202010503" } ] })
    expect([ same.payload[:addendum].item_changes, same.payload[:structured] ]).to eq([ {}, false ])
    justified = add(changes: { "exam_requests" => [ { "sigtap_code" => "0202010503", "cid10_justification" => "E119" } ] })
    expect(justified.payload[:addendum].item_changes.keys).to eq([ "exam_requests" ])
    expect(Consultations::Effective.call(consultation.reload)[:exam_requests].sole.cid10_justification).to eq("E119")
  end

  it "lista de condutas vazia → no_conduct; chave desconhecida ou lista que não é lista → invalid_changes / 422; nada fica" do
    expect(add(changes: { "conducts" => [] }).reason).to eq(:no_conduct)
    expect(add(changes: { "conducts_added" => [ 9 ] }).reason).to eq(:invalid_changes)
    expect(add(changes: { "conducts" => "9" }).reason).to eq(:invalid_conduct)
    expect(add(changes: { "exam_requests" => [ { "sigtap_code" => "0301010064" } ] }).reason).to eq(:invalid_exam)
    expect(ConsultationAddendum.count).to eq(0)
  end
end
