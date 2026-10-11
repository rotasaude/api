require "rails_helper"

# Rascunho de consulta órfão (card rotasaude/api#51; módulo 19a, ADR 0031):
# o admin municipal descarta — a consulta vira casca (`discarded`, conteúdo
# clínico zerado), a trilha guarda a autora e o motivo cifrado, o evento leva
# só ids. Nada de ficha, problema ou conduta; documentos emitidos ficam; o
# atendimento segue in_care e o desfecho sai pela rota normal.
RSpec.describe ConsultationDrafts::Discard do
  include ActiveJob::TestHelper

  before { Current.city = documents_city!; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:admin) { staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }
  let(:reason) { "Profissional desligada da unidade, rascunho sem dono" }
  let(:consultation) do
    started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)).tap do |c|
      saved = Consultations::SaveDraft.call(consultation: c, params: draft_body(subjective: "MARCADOR-S"), by: doctor)
      raise "rascunho recusado: #{saved.reason}" if saved.failure?

      # Órfão real: a autora perde o vínculo da unidade.
      ProfessionalLink.joins(:professional).where(professionals: { user_id: doctor.id })
                      .find_each { |link| link.update!(ended_at: Time.current, ended_by_user: admin) }
    end
  end

  def discard(id: consultation.id, why: reason, by: admin) = described_class.call(consultation_id: id, reason: why, by: by)

  it "motivo curto, longo ou não string → invalid_reason, sem tocar no rascunho" do
    [ "curto", "x" * 501, nil, [ "motivo suficiente" ], 12_345_678_901 ].each do |bad|
      expect(discard(why: bad).reason).to eq(:invalid_reason), bad.inspect
    end
    expect(discard(why: "  #{'a ' * 4}b  ").reason).to eq(:invalid_reason) # 9 depois do squish
    expect(consultation.reload).to have_attributes(status: "draft", subjective: "MARCADOR-S")
    expect(ConsultationDraftAction.count).to eq(0)
  end

  it "interruptor clinical_record desligado → feature_disabled" do
    consultation
    Platform::Features.set!(city: Current.city, key: "clinical_record", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    expect(discard.reason).to eq(:feature_disabled)
  end

  it "inexistente ou id inválido → not_found; finalizada ou já descartada → not_draft" do
    expect(discard(id: SecureRandom.uuid).reason).to eq(:not_found)
    expect(discard(id: "lixo").reason).to eq(:not_found)
    finalized = finalized_consultation!(unit: unit, doctor: doctor!(unit), citizen: verified_citizen!(2, full_name: "Rita Souza"))
    expect(discard(id: finalized.id).reason).to eq(:not_draft)
    expect(discard).to be_ok
    expect(discard.reason).to eq(:not_draft)
    expect(ConsultationDraftAction.count).to eq(1)
  end

  it "zera o conteúdo clínico, marca discarded, grava a trilha e publica só ids" do
    attendance_id = consultation.attendance_id
    result = nil
    expect { result = discard }.not_to have_enqueued_job(Ledi::ConsultationFichaJob)
    expect(result).to be_ok
    expect(result.payload[:consultation].id).to eq(consultation.id)

    fresh = Consultation.find(consultation.id)
    expect(fresh).to have_attributes(status: "discarded", draft_items: {}, author_user_id: doctor.id,
                                     attendance_id: attendance_id)
    expect(fresh.discarded_at).to be_present
    Consultation::CLINICAL_COLUMNS.each { |column| expect(fresh[column]).to be_nil, column }
    raw = ApplicationRecord.connection.select_one("SELECT subjective, plan FROM consultations WHERE id = #{ApplicationRecord.connection.quote(fresh.id)}")
    expect(raw.values).to eq([ nil, nil ])

    action = ConsultationDraftAction.sole
    expect(action).to have_attributes(action: "discarded", consultation_id: fresh.id, attendance_id: fresh.attendance_id,
                                      previous_author_user_id: doctor.id, new_author_user_id: nil, by_user_id: admin.id,
                                      reason: reason)

    event = DomainEvent.where(name: "consultation.draft_discarded").sole
    expect(event.payload).to eq("consultation_id" => fresh.id, "attendance_id" => attendance_id,
                                "author_user_id" => doctor.id, "by_user_id" => admin.id)
    expect(DomainEvent.pluck(:payload).to_json).not_to include("MARCADOR", "desligada")

    expect(ConsultationProblem.count).to eq(0)
    expect(ConsultationConduct.count).to eq(0)
    expect(ConsultationExamRequest.count).to eq(0)
    expect(PatientProblem.where(patient_id: fresh.patient_id)).to be_empty
    expect(fresh.attendance.reload.status).to eq("in_care")
  end

  it "a trilha usa o atendimento da própria consulta" do
    other = walk_in_attendance!(unit, citizen: verified_citizen!(3, full_name: "Ana Lima"))
    discard
    expect(ConsultationDraftAction.sole.attendance_id).to eq(consultation.attendance_id)
    expect(ConsultationDraftAction.sole.attendance_id).not_to eq(other.id)
  end

  it "depois do descarte o desfecho sai pela rota normal (antes: consultation_in_progress)" do
    colleague = doctor!(unit)
    close = -> { Attendances::Close.call(attendance: consultation.attendance.reload, outcome: "discharged", referral_unit_id: nil, referral_note: nil, by: colleague) }
    expect(close.call.reason).to eq(:consultation_in_progress)
    discard
    expect(close.call).to be_ok
    expect(consultation.attendance.reload).to have_attributes(status: "closed", outcome: "discharged")
  end

  it "documento clínico emitido no rascunho continua intacto" do
    consultation
    issued = ClinicalDocuments::Issue.call(kind: "sick_note", content: { "type" => "leave", "days" => 2 }, by: doctor,
                                           consultation: consultation)
    expect(issued).to be_ok
    document = issued.payload[:document]
    expect(discard).to be_ok
    expect(document.reload).to have_attributes(status: "issued", consultation_id: consultation.id)
    expect(document.content_data).to include("type" => "leave", "days" => 2)
  end
end
