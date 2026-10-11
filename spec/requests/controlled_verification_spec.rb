require "rails_helper"

# Contrato §7; spec §6; ADR 0034 (Invariantes): a conferência mostra a
# categoria e o número SNCR; nunca medicamento, CPF, endereço ou telefone; a
# cancelada avisa que o SNCR não registra o cancelamento.
RSpec.describe "Conferência pública da receita controlada", type: :request do
  before do
    controlled_city!(mock: true)
    ciap2_release!; cid10_release!; sigtap_release!; city_profile!
    import_test_catalog!
  end

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit).tap { |user| prescriber_contact!(user); linked_certificate!(user) } }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  def rce!
    sncr_stock!(doctor, kind: "rce", count: 1)
    ClinicalDocuments::Issue.call(kind: "prescription", by: doctor, consultation: consultation, content: {
      "items" => [ { "catalog_item" => { "id" => controlled_item!(code: 9_900_001, ingredient: "FLUOXETINA", list: "C1").id },
                     "quantity" => 30, "quantity_unit" => "cápsula", "route" => "oral", "dosage_instructions" => "1 cápsula",
                     "duration_days" => 30 } ],
      "patient_identification" => patient_identification
    }).payload.fetch(:document)
  end

  it "JSON e HTML: categoria e numeração, nada do paciente nem do medicamento" do
    document = rce!
    get "/v/#{document.verification_token}", headers: { "Accept" => "application/json" }
    json = JSON.parse(response.body)
    expect(json).to include("kind" => "prescription", "category" => "special_control",
                            "sncr" => { "kind" => "rce", "number" => "2610.1-41.0000001", "simulated" => true })
    expect(response.body).not_to include("FLUOXETINA", consultation.patient.cpf, "Araucárias", "99999")
    get "/v/#{document.verification_token}"
    expect(response.body).to include("Receita de controle especial", "2610.1-41.0000001", "simulada — sem validade")
    expect(response.body).not_to include("FLUOXETINA", "Araucárias")
  end

  it "cancelada: aviso de não dispensar; receita comum sem sncr" do
    document = rce!
    ClinicalDocuments::Cancel.call(document_id: document.id, by: doctor, reason: "Dose errada, vou reemitir")
    get "/v/#{document.verification_token}"
    expect(response.body).to include("Cancelado", "não dispense", "O SNCR não registra o cancelamento")
    common = ClinicalDocuments::Issue.call(kind: "prescription", by: doctor, consultation: consultation, content: {
      "items" => [ { "catalog_item" => { "id" => catalog_item(268_856).id }, "quantity" => 30, "quantity_unit" => "comprimido",
                     "route" => "oral", "dosage_instructions" => "1 comprimido" } ]
    }).payload.fetch(:document)
    get "/v/#{common.verification_token}", headers: { "Accept" => "application/json" }
    expect(JSON.parse(response.body)).to include("category" => "common")
    expect(JSON.parse(response.body)).not_to have_key("sncr")
  end
end
