require "rails_helper"

# ADR 0034 (Invariantes: número de receita cancelada não volta; Desvio 11):
# cancelar e voltar ao papel anulam o número. A asserção de que o PDF de papel
# não imprime o número entra na Task 15 (o PDF ainda não conhece o número).
RSpec.describe "Número SNCR no cancelamento e na volta ao papel" do
  before do
    controlled_city!(mock: true)
    ciap2_release!; cid10_release!; sigtap_release!; city_profile!
    import_test_catalog!
  end

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit).tap { |user| prescriber_contact!(user); linked_certificate!(user) } }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }
  let(:fluoxetina) { controlled_item!(code: 9_900_001, ingredient: "FLUOXETINA", list: "C1") }

  def rce!
    sncr_stock!(doctor, kind: "rce", count: 1)
    ClinicalDocuments::Issue.call(kind: "prescription", by: doctor, consultation: consultation, content: {
      "items" => [ { "catalog_item" => { "id" => fluoxetina.id }, "quantity" => 30, "quantity_unit" => "cápsula", "route" => "oral",
                     "dosage_instructions" => "1 cápsula pela manhã", "duration_days" => 30 } ],
      "patient_identification" => patient_identification
    }).payload.fetch(:document)
  end

  it "cancelar anula o número, com eventos só com ids e a categoria" do
    document = rce!
    ClinicalDocuments::Cancel.call(document_id: document.id, by: doctor, reason: "Dose errada, vou reemitir")
    expect(SncrNumber.find_by(document_id: document.id).status).to eq("voided")
    cancelled = DomainEvent.where(name: "clinical_document.cancelled").order(:created_at).last.payload
    expect(cancelled).to eq("document_id" => document.id, "kind" => "prescription", "category" => "special_control")
    voided = DomainEvent.where(name: "sncr.number_voided").order(:created_at).last.payload
    expect(voided).to eq("document_id" => document.id, "kind" => "rce")
  end

  it "voltar ao papel anula o número e o cancelamento seguinte não quebra" do
    document = rce!
    Signatures::ReturnToPaper.call(request_id: document.signature_request.id, by: doctor, reason: "Paciente pediu o papel agora")
    expect(document.reload.issue_mode).to eq("paper")
    expect(SncrNumber.find_by(document_id: document.id).status).to eq("voided")
    result = ClinicalDocuments::Cancel.call(document_id: document.id, by: doctor, reason: "Cancelando a de papel também")
    expect(result).to be_ok
    expect(SncrNumber.find_by(document_id: document.id).status).to eq("voided")
  end
end
