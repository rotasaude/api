require "rails_helper"

# Contrato §4: medicamentos em uso (leitura como o prontuário; escrita da
# autora na consulta em rascunho) e a renovação dos contínuos.
RSpec.describe "Medicamentos em uso", type: :request do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release!; import_test_catalog! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(1) }

  it "na consulta em rascunho: informar de fora, suspender, reativar; erros 409/422; lista do paciente" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external",
              catalog_item_id: catalog_item(267_772).id, dosage_summary: "1 cp 12/12h"
    expect(response).to have_http_status(:ok)
    medication = json_body
    expect(medication).to include("label" => "PROPRANOLOL CLORIDRATO 40 MG", "status" => "active", "origin" => "external",
                                  "catalog_item" => include("catmat_code" => 267_772))
    json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", catalog_item_id: catalog_item(267_772).id
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_active" } ])
    json_post "/attendance/consultations/#{draft.id}/medications", action: "suspend", medication_id: medication["id"]
    expect(json_body["status"]).to eq("suspended")
    json_post "/attendance/consultations/#{draft.id}/medications", action: "reactivate", medication_id: medication["id"]
    expect(json_body["status"]).to eq("active")
    json_post "/attendance/consultations/#{draft.id}/medications", action: "suspend", medication_id: SecureRandom.uuid
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_medication" } ])
    json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", free_text: "x"
    expect(json_body).to eq("error" => "invalid_content", "field" => "free_text")

    get "/attendance/patients/#{draft.patient_id}/medications"
    expect(json_body["items"].map { |item| item["id"] }).to eq([ medication["id"] ])
  end

  # 27a (H7): `last_dispensed_on` por item da lista; só leitura (nada novo em
  # patient_medication_events); a última dispensação LÍQUIDA de devolução total;
  # data no fuso da cidade; texto livre e item nunca dispensado → null.
  describe "last_dispensed_on (27a)" do
    let(:draft) { started_consultation!(unit: unit, doctor: doctor, citizen: citizen) }
    let(:farmacia) { unit_location!(create_unit("UBS Farmácia")) }
    let(:farmaceutico) { pharmacy_admin! }
    let(:zone) { Current.city.time_zone }
    let(:today) { Time.use_zone(zone) { Time.zone.today } }

    def inform!(catalog: nil, free_text: nil)
      json_post "/attendance/consultations/#{draft.id}/medications", { action: "add_external", catalog_item_id: catalog&.id, free_text: free_text }.compact
      expect(response).to have_http_status(:ok)
      json_body["id"]
    end

    # Dispensação gravada direto (a lista só lê): 23:30 no fuso da cidade, `days` dias atrás.
    def dispensed!(catalog, days_ago:, quantity: 30)
      at = Time.use_zone(zone) { (today - days_ago).in_time_zone.change(hour: 23, min: 30) }
      document = pharmacy_prescription!(consultation: draft, items: [ { catalog: catalog } ])
      lot = StockLot.find_or_create_by!(catalog_item_id: catalog.id, lot_number: "LOTE-LM") do |row|
        row.assign_attributes(catmat_code: catalog.catmat_code, expires_on: Time.zone.today + 90, dispensing_unit: "comprimido", created_by_user: farmaceutico)
      end
      dispensation = Dispensation.create!(stock_location: farmacia, patient: draft.patient, clinical_document: document, dispensed_by_user: farmaceutico,
                                          dispensed_by_role: "pharmacist", dispensed_at: at)
      DispensationItem.create!(dispensation: dispensation, prescription_item: document.prescription_items.first, stock_lot: lot,
                               catalog_item_id: catalog.id, quantity: quantity)
    end

    def last_dispensed = json_body["items"].to_h { |row| [ row["label"], row["last_dispensed_on"] ] }
    def listed = (get("/attendance/patients/#{draft.patient_id}/medications") && last_dispensed)

    before { sign_in_as(doctor) }

    it "losartana em uso dispensada há 3 dias → essa data (fuso da cidade); sem dispensação e texto livre → null; nada novo nos eventos" do
      inform!(catalog: catalog_item(268_856))
      inform!(catalog: catalog_item(267_772))
      inform!(free_text: "Chá de boldo")
      dispensed!(catalog_item(268_856), days_ago: 3)
      events = PatientMedicationEvent.count
      expect(listed).to eq("LOSARTANA POTÁSSICA 50 MG" => (today - 3).iso8601, "PROPRANOLOL CLORIDRATO 40 MG" => nil, "Chá de boldo" => nil)
      expect(json_body["items"].first.keys).to include("last_dispensed_on")
      expect(PatientMedicationEvent.count).to eq(events)
    end

    it "vale a mais recente; com o interruptor da farmácia desligado a lista continua mostrando" do
      inform!(catalog: catalog_item(268_856))
      dispensed!(catalog_item(268_856), days_ago: 40)
      dispensed!(catalog_item(268_856), days_ago: 10)
      Platform::Features.set!(city: Current.city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)
      expect(listed).to eq("LOSARTANA POTÁSSICA 50 MG" => (today - 10).iso8601)
    end

    it "coerente com a devolução: a retirada devolvida por inteiro não conta; a devolução parcial mantém" do
      inform!(catalog: catalog_item(268_856))
      older = dispensed!(catalog_item(268_856), days_ago: 40)
      newer = dispensed!(catalog_item(268_856), days_ago: 10)
      expect(listed).to eq("LOSARTANA POTÁSSICA 50 MG" => (today - 10).iso8601)
      give_back = ->(row, quantity) { Pharmacy::RecordReturn.call(location: farmacia, dispensation_item: row, quantity: quantity, reason: "Receita trocada pelo médico", by: farmaceutico) }
      expect(give_back.call(newer, "5")).to be_ok
      expect(listed).to eq("LOSARTANA POTÁSSICA 50 MG" => (today - 10).iso8601)
      expect(give_back.call(newer, "25")).to be_ok
      expect(listed).to eq("LOSARTANA POTÁSSICA 50 MG" => (today - 40).iso8601)
      expect(give_back.call(older, "30")).to be_ok
      expect(listed).to eq("LOSARTANA POTÁSSICA 50 MG" => nil)
    end
  end

  it "consulta finalizada não muda a lista por esta rota (409 not_draft); outro profissional 403" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{consultation.id}/medications", action: "add_external", free_text: "Chá de boldo"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "not_draft" } ])
    sign_in_as(doctor!(unit))
    get "/attendance/patients/#{consultation.patient_id}/medications"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_context" } ])
  end

  # Card api#51 (revisão final): a designação entra entre a leitura da
  # consulta pelo controlador e a trava; a autoria é relida sob a trava da
  # consulta e a autora antiga recebe 403 not_author, sem gravar nada.
  it "rascunho designado entre a leitura e a trava: a autora antiga → 403 not_author, nada gravado" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    colleague = doctor!(unit)
    admin = staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")
    allow_any_instance_of(PatientMedicationsController).to receive(:find_consultation).and_wrap_original do |original|
      original.call.tap do
        result = ConsultationDrafts::Reassign.call(consultation_id: draft.id, user_id: colleague.id,
                                                   reason: "Autora afastada; segue com o colega", by: admin)
        raise "designação recusada: #{result.reason}" if result.failure?
      end
    end
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", free_text: "Chá de boldo"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])
    expect(PatientMedication.where(patient_id: draft.patient_id)).to be_empty
    expect(draft.reload.author_user_id).to eq(colleague.id)
  end

  it "renovação: os contínuos ativos, com a última posologia da receita" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    content = { "items" => [ { "catalog_item" => { "id" => catalog_item(268_856).id }, "quantity" => 30, "quantity_unit" => "comprimido",
                               "route" => "oral", "dosage_instructions" => "1 comprimido pela manhã", "duration_days" => 30,
                               "continuous" => true } ] }
    ClinicalDocuments::Issue.call(kind: "prescription", content: content, by: doctor, consultation: consultation)
    # A renovação segue a regra de contexto (fix round 1): na consulta seguinte, com o paciente em atendimento.
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(doctor)
    get "/attendance/consultations/#{consultation.id}/renewal"
    expect(json_body["items"]).to eq([ { "position" => 1, "catalog_item" => ClinicalDocuments::Json.catalog_ref(catalog_item(268_856)).as_json.merge("controlled_list" => nil, "anticonvulsant" => false),
                                         "printed_description" => "LOSARTANA POTÁSSICA 50 MG", "quantity" => 30,
                                         "quantity_unit" => "comprimido", "route" => "oral",
                                         "dosage_instructions" => "1 comprimido pela manhã", "duration_days" => 30,
                                         "continuous" => true, "antimicrobial" => false } ])
    sign_in_as(doctor!(unit))
    get "/attendance/consultations/#{consultation.id}/renewal"
    expect(json_body).to eq("error" => "not_author")
  end

  # Decisão do controlador (Task 12): o comando não trava; o controller trava o
  # paciente. O texto livre não tem índice único (a comparação é em Ruby sobre
  # o texto cifrado): o segundo "informar" igual (outra caixa e espaços) é
  # 409, sem duplicar e sem 500.
  it "informar o mesmo medicamento de fora duas vezes (texto livre) → 409 already_active, uma linha só" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", free_text: "Chá de boldo",
                                                                   continuous: false
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("label" => "Chá de boldo", "free_text" => "Chá de boldo", "catalog_item" => nil,
                                 "continuous" => false, "origin" => "external")
    json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", free_text: "  chá DE   boldo "
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_active" } ])
    expect(PatientMedication.where(patient_id: draft.patient_id).count).to eq(1)
  end

  it "o medicamento informado não vai ao log (texto, posologia e id do catálogo filtrados)" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(doctor)
    id = catalog_item(267_772).id
    log = capture_log do
      json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", catalog_item_id: id,
                                                                     dosage_summary: "1 cp de propranolol 12/12h"
      json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", free_text: "Chá de boldo"
    end
    expect(response).to have_http_status(:ok)
    parameters = log.lines.grep(/Parameters:/)
    expect(parameters.size).to eq(2)
    expect(parameters.join).to include("[FILTERED]")
    expect(parameters.join).not_to include(id)
    expect(log).not_to include("propranolol")
    expect(log).not_to include("boldo")
  end

  it "escrita: interruptor desligado 403 feature_disabled (leitura segue); não autora 403 not_author; corpo inválido 422" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(doctor!(unit))
    json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", free_text: "Chá de boldo"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{draft.id}/medications", action: "remove", medication_id: SecureRandom.uuid
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_content", "field" => "action" } ])
    json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", catalog_item_id: SecureRandom.uuid
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_content", "field" => "catalog_item_id" } ])
    json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", free_text: "Chá de boldo",
                                                                   dosage_summary: "x" * 201
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_content", "field" => "dosage_summary" } ])
    expect(PatientMedication.where(patient_id: draft.patient_id)).to be_empty
    documents_city!(enabled: false)
    json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", free_text: "Chá de boldo"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "clinical_documents" } ])
    get "/attendance/patients/#{draft.patient_id}/medications"
    expect([ response.status, json_body ]).to eq([ 200, { "items" => [] } ])
    get "/attendance/consultations/#{draft.id}/renewal"
    expect([ response.status, json_body ]).to eq([ 200, { "items" => [] } ])
  end

  it "recepção não lê nem escreve (403 missing_role); paciente inexistente 404" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(verifier!)
    get "/attendance/patients/#{draft.patient_id}/medications"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", free_text: "Chá de boldo"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    sign_in_as(doctor)
    get "/attendance/patients/#{SecureRandom.uuid}/medications"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end

  # Fix round 1: a renovação expõe a lista do paciente — mesma regra e mesma
  # trilha do GET de medicamentos (a autora fora de contexto não lê por aqui).
  it "renovação: autora fora de contexto 403 out_of_context; em contexto 200 com trilha" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen) # finalizar encerra o atendimento
    sign_in_as(doctor)
    get "/attendance/consultations/#{consultation.id}/renewal"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_context" } ])
    get "/attendance/patients/#{consultation.patient_id}/medications"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_context" } ])

    draft = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    expect { get "/attendance/consultations/#{draft.id}/renewal" }
      .to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    expect([ response.status, json_body ]).to eq([ 200, { "items" => [] } ])
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).last.payload)
      .to include("access" => "in_context", "user_id" => doctor.id, "patient_id" => draft.patient_id)
  end

  it "consulta finalizada entre a checagem e a trava do paciente → 409 not_draft, nada gravado" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(doctor)
    allow_any_instance_of(Consultation).to receive(:draft?).and_return(true, false)
    json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", free_text: "Chá de boldo"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "not_draft" } ])
    expect(PatientMedication.where(patient_id: draft.patient_id)).to be_empty
  end

  it "continuous não booleano → 422 invalid_content field continuous" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(doctor)
    [ nil, "true", 1 ].each do |value|
      json_post "/attendance/consultations/#{draft.id}/medications", action: "add_external", free_text: "Chá de boldo",
                                                                     continuous: value
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_content", "field" => "continuous" } ])
    end
    expect(PatientMedication.where(patient_id: draft.patient_id)).to be_empty
  end

  it "leitura da lista em contexto deixa trilha in_context" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(doctor)
    get "/attendance/patients/#{draft.patient_id}/medications"
    expect(response).to have_http_status(:ok)
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).last.payload)
      .to include("access" => "in_context", "user_id" => doctor.id, "patient_id" => draft.patient_id)
  end
end
