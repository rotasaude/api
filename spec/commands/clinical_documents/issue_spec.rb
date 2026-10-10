# spec/commands/clinical_documents/issue_spec.rb
require "rails_helper"

# Spec §4–§5; ADR 0033: emissão da consulta (autora, também depois de
# finalizada) e do atendimento (declaração, sempre papel); modo escolhido no
# ato e nunca convertido; antimicrobiano sempre papel; receita de uso
# contínuo alimenta a lista de medicamentos.
RSpec.describe ClinicalDocuments::Issue do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }
  let(:leave) { { "type" => "leave", "days" => 2 } }

  def issue(kind: "sick_note", content: leave, by: doctor, **args) = described_class.call(kind: kind, content: content, by: by, consultation: consultation, **args)

  it "atestado da autora: papel, códigos, conteúdo cifrado, evento só com ids" do
    document = issue.payload[:document]
    expect(document).to have_attributes(kind: "sick_note", status: "issued", issue_mode: "paper", author_user_id: doctor.id,
                                        cbo_code: "225125", patient_id: consultation.patient_id,
                                        attendance_id: consultation.attendance_id)
    expect(document.short_code).to match(/\A[2-9ABCDEFGHJKMNPQRSTUVWXYZ]{10}\z/)
    expect(document.verification_token.size).to eq(22)
    expect(document.content_data).to include("type" => "leave", "days" => 2)
    # SQL cru: pluck/pick com o nome da coluna passaria pelo tipo cifrado e devolveria o texto claro.
    raw = ApplicationRecord.connection.select_value("SELECT content FROM clinical_documents WHERE id = #{ApplicationRecord.connection.quote(document.id)}")
    expect(raw).not_to include("leave")
    expect(DomainEvent.where(name: "clinical_document.issued").last.payload)
      .to eq("document_id" => document.id, "kind" => "sick_note", "consultation_id" => consultation.id, "issue_mode" => "paper")
  end

  it "não autora → not_author; enfermeira não emite atestado → cbo_not_allowed; falha não grava nada" do
    expect(issue(by: doctor!(unit)).reason).to eq(:not_author)
    nurse = nurse!(unit)
    nursing = finalized_consultation!(unit: unit, doctor: nurse, citizen: verified_citizen!(2, full_name: "Rita Souza"))
    expect(described_class.call(kind: "sick_note", content: leave, by: nurse, consultation: nursing).reason).to eq(:cbo_not_allowed)
    expect { issue(content: { "type" => "leave", "days" => 0 }) }.not_to change(ClinicalDocument, :count)
  end

  it "digital quando a assinatura está utilizável e a autora tem certificado; nasce o pedido pending" do
    signature_city!
    linked_certificate!(doctor.tap { |u| u.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF) })
    document = issue.payload[:document]
    expect(document.issue_mode).to eq("digital")
    request = SignatureRequest.find_by(document_type: "ClinicalDocument", document_id: document.id)
    expect(request).to have_attributes(status: "pending", consultation_id: consultation.id, author_user_id: doctor.id)
    # A consulta finalizada com certificado também enfileirou o dela: confere o do documento.
    expect(Signatures::SignJob).to have_been_enqueued.with(hash_including(request_id: request.id))
  end

  it "antimicrobiano sai em papel mesmo com assinatura e certificado" do
    import_test_catalog!
    signature_city!
    linked_certificate!(doctor.tap { |u| u.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF) })
    content = { "items" => [ { "catalog_item" => { "id" => catalog_item(271_089).id }, "quantity" => 21, "quantity_unit" => "cápsula",
                               "route" => "oral", "dosage_instructions" => "1 cápsula de 8/8h por 7 dias" } ] }
    document = issue(kind: "prescription", content: content).payload[:document]
    expect([ document.issue_mode, document.content_data["copies"] ]).to eq([ "paper", 2 ])
    expect(SignatureRequest.where(document_id: document.id)).to be_empty
  end

  it "receita: itens gravados; uso contínuo entra na lista de medicamentos; a receita repetida não duplica (Review Focus 2)" do
    import_test_catalog!
    content = { "items" => [ { "catalog_item" => { "id" => catalog_item(268_856).id }, "quantity" => 30, "quantity_unit" => "comprimido",
                               "route" => "oral", "dosage_instructions" => "1 comprimido pela manhã", "continuous" => true },
                             { "free_text" => "Chá de camomila", "quantity" => 1, "quantity_unit" => "caixa", "route" => "oral",
                               "dosage_instructions" => "1 sachê à noite por 5 dias" } ] }
    first = issue(kind: "prescription", content: content).payload[:document]
    expect(first.prescription_items.map(&:position)).to eq([ 1, 2 ])
    medication = PatientMedication.sole
    expect(medication).to have_attributes(catmat_code: 268_856, status: "active", origin: "prescription", dosage_summary: "1 comprimido pela manhã")
    expect(medication.events.sole.clinical_document_id).to eq(first.id)

    second = issue(kind: "prescription", content: content).payload[:document]
    expect(PatientMedication.count).to eq(1)
    expect(medication.events.count).to eq(1) # mesma posologia: nada muda
    content["items"][0]["dosage_instructions"] = "1 comprimido de 12/12h"
    issue(kind: "prescription", content: content)
    expect(medication.events.order(:created_at).last).to have_attributes(kind: "changed")
    expect(second.id).not_to eq(first.id)
  end

  it "sem catálogo ativo → catalog_unavailable" do
    content = { "items" => [ { "free_text" => "Chá de camomila", "quantity" => 1, "quantity_unit" => "caixa", "route" => "oral",
                               "dosage_instructions" => "1 sachê" } ] }
    expect(issue(kind: "prescription", content: content).reason).to eq(:catalog_unavailable)
  end

  it "declaração pelo atendimento: recepção, papel, sem consulta nem CBO; atendimento antigo → 409; outro tipo recusado" do
    attendance = consultation.attendance
    document = described_class.call(kind: "attendance_declaration", content: { "issuer_registration" => "4471" },
                                    by: verifier!, attendance: attendance).payload[:document]
    expect(document).to have_attributes(issue_mode: "paper", consultation_id: nil, cbo_code: nil,
                                        patient_id: consultation.patient_id, citizen_id: attendance.citizen_id)
    expect(DomainEvent.where(name: "clinical_document.issued").last.payload).to include("attendance_id" => attendance.id)
    expect(described_class.call(kind: "sick_note", content: leave, by: verifier!, attendance: attendance).details).to eq(field: "kind")
    old_visit = walk_in_attendance!(unit, citizen: verified_citizen!(3, full_name: "Ivo Lima"), checked_in_at: 31.days.ago)
    expect(described_class.call(kind: "attendance_declaration", content: {}, by: verifier!, attendance: old_visit).reason)
      .to eq(:attendance_not_found_or_closed_long_ago)
    expect(described_class.call(kind: "attendance_declaration", content: {}, by: municipal_admin!, attendance: consultation.attendance).reason)
      .to eq(:missing_role)
  end

  it "substituição: só de um documento cancelado do mesmo tipo e da mesma autora" do
    old = issue.payload[:document]
    expect(issue(replaces_document_id: old.id).details).to eq(field: "replaces_document_id")
    old.update!(status: "cancelled", cancel_reason: "Dias errados no atestado", cancelled_at: Time.current, cancelled_by_user_id: doctor.id)
    expect(issue(replaces_document_id: old.id).payload[:document].replaces_document_id).to eq(old.id)
    expect(issue(kind: "attendance_declaration", content: {}, replaces_document_id: old.id).details).to eq(field: "replaces_document_id")
  end

  it "o JSON do documento segue o contrato §2" do
    document = issue.payload[:document]
    json = ClinicalDocuments::Json.document(document).as_json
    expect(json.keys).to match_array(%w[id kind status issue_mode issued_at cancelled_at cancel_reason author patient consultation_id
                                        attendance_id short_code verification_url replaces_document_id content signature])
    expect(json["author"]).to eq("id" => doctor.id, "name" => doctor.professional.professional_name,
                                 "council" => "#{doctor.professional.council}-#{doctor.professional.council_state} #{doctor.professional.registration_number}",
                                 "cbo_code" => "225125")
    expect(json["short_code"]).to match(/\A[2-9A-Z]{5}-[2-9A-Z]{5}\z/)
    expect(json["verification_url"]).to end_with("/v/#{document.verification_token}")
    expect(json["signature"]).to be_nil
  end
end
