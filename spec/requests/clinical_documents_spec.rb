require "rails_helper"

# Contrato §3: emitir e ler documentos da consulta e do atendimento. Leitura
# pelas regras do 19a (autora sempre; outro profissional em contexto ou por
# abertura), com trilha.
RSpec.describe "Documentos clínicos", type: :request do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }

  it "a autora emite (201 <document>), lista e lê; trilha author" do
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note", content: { type: "leave", days: 3 }
    expect(response).to have_http_status(:created)
    document = json_body
    expect(document).to include("kind" => "sick_note", "status" => "issued", "issue_mode" => "paper",
                                "consultation_id" => consultation.id, "content" => include("days" => 3))
    get "/attendance/consultations/#{consultation.id}/documents"
    expect(json_body["items"].map { |item| item["id"] }).to eq([ document["id"] ])
    get "/attendance/documents/#{document['id']}"
    expect(json_body["id"]).to eq(document["id"])
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload).to include("access" => "author")
  end

  # A46 aplicado aos documentos: o polling da tela (assinatura pendente) lê só
  # o estado, sem conteúdo e sem trilha; a lista completa segue com trilha.
  it "status: só id, status e modo da assinatura, sem trilha; mesma regra de acesso da lista" do
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note", content: { type: "leave", days: 3 }
    id = json_body["id"]
    expect { get "/attendance/consultations/#{consultation.id}/documents/status" }
      .not_to(change { DomainEvent.where(name: "clinical_record.viewed").count })
    expect([ response.status, json_body ]).to eq([ 200, { "items" => [ { "id" => id, "status" => "issued", "signature_mode" => nil } ] } ])
    expect { get "/attendance/consultations/#{consultation.id}/documents" }
      .to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    sign_in_as(nurse!(unit))
    get "/attendance/consultations/#{consultation.id}/documents/status"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_context" } ])
    sign_in_as(verifier!)
    get "/attendance/consultations/#{consultation.id}/documents/status"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    sign_in_as(doctor)
    get "/attendance/consultations/#{SecureRandom.uuid}/documents/status"
    expect(response).to have_http_status(:not_found)
  end

  it "erros do contrato: 403 not_author/cbo_not_allowed, 422 com field/index, 503 sem catálogo, 403 interruptor" do
    sign_in_as(doctor!(unit))
    json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note", content: { type: "leave", days: 3 }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note", content: { type: "leave", days: 0 }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_content", "field" => "days" } ])
    json_post "/attendance/consultations/#{consultation.id}/documents", kind: "prescription",
              content: { items: [ { free_text: "Chá", quantity: 1, quantity_unit: "caixa", route: "oral", dosage_instructions: "1 sachê" } ] }
    expect([ response.status, json_body ]).to eq([ 503, { "error" => "catalog_unavailable" } ])
    import_test_catalog!
    json_post "/attendance/consultations/#{consultation.id}/documents", kind: "prescription",
              content: { items: [ { catalog_item: { id: catalog_item(267_197).id }, quantity: 10, quantity_unit: "comprimido",
                                    route: "oral", dosage_instructions: "1 à noite" } ] }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "controlled_not_allowed", "index" => 0 } ])
    documents_city!(enabled: false)
    json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note", content: { type: "leave", days: 3 }
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "clinical_documents")
    get "/attendance/consultations/#{consultation.id}/documents"
    expect(response).to have_http_status(:ok) # leitura segue com o interruptor desligado
  end

  it "outro profissional: fora de contexto 403; em contexto lê com trilha in_context; recepção não lê documento alheio" do
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note", content: { type: "leave", days: 3 }
    id = json_body["id"]
    nurse = nurse!(unit)
    sign_in_as(nurse)
    get "/attendance/documents/#{id}"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_context" } ])
    walk_in_attendance!(unit, citizen: consultation.attendance.citizen)
    get "/attendance/documents/#{id}"
    expect(response).to have_http_status(:ok)
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload).to include("access" => "in_context", "user_id" => nurse.id)
    sign_in_as(verifier!)
    get "/attendance/documents/#{id}"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "declaração pela recepção: 201 em papel; ela lê a própria; atendimento inexistente 404" do
    reception = verifier!
    sign_in_as(reception)
    json_post "/attendance/attendances/#{consultation.attendance_id}/declarations", content: { issuer_registration: "4471" }, health_unit_id: consultation.attendance.health_unit_id
    expect(response).to have_http_status(:created)
    expect(json_body).to include("kind" => "attendance_declaration", "issue_mode" => "paper", "consultation_id" => nil,
                                 "author" => include("id" => reception.id, "cbo_code" => nil))
    get "/attendance/documents/#{json_body['id']}"
    expect(response).to have_http_status(:ok)
    json_post "/attendance/attendances/#{SecureRandom.uuid}/declarations", content: {}, health_unit_id: unit.id
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    sign_in_as(municipal_admin!)
    json_post "/attendance/attendances/#{consultation.attendance_id}/declarations", content: {}, health_unit_id: consultation.attendance.health_unit_id
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  # Decisão do controlador: a declaração pelo atendimento é da unidade. O
  # profissional precisa de vínculo ativo NA unidade do atendimento (o da
  # outra unidade recebe 403 missing_role); a recepção (citizen_verifier) não
  # tem escopo de unidade no modelo (memberships é da cidade inteira — o
  # check-in e a fila também não restringem a unidade).
  it "declaração pelo atendimento: profissional de outra unidade 403 missing_role; o da unidade emite com o CBO do vínculo" do
    sign_in_as(doctor!(create_unit("UBS Norte")))
    json_post "/attendance/attendances/#{consultation.attendance_id}/declarations", content: {}, health_unit_id: consultation.attendance.health_unit_id
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    nurse = nurse!(unit)
    sign_in_as(nurse)
    json_post "/attendance/attendances/#{consultation.attendance_id}/declarations", content: {}, health_unit_id: consultation.attendance.health_unit_id
    expect(response).to have_http_status(:created)
    expect(json_body).to include("author" => include("id" => nurse.id, "cbo_code" => "223505"), "signature" => nil)
  end

  it "declaração com o interruptor desligado: 403 feature_disabled; leitura do documento segue" do
    sign_in_as(verifier!)
    json_post "/attendance/attendances/#{consultation.attendance_id}/declarations", content: {}, health_unit_id: consultation.attendance.health_unit_id
    id = json_body["id"]
    documents_city!(enabled: false)
    json_post "/attendance/attendances/#{consultation.attendance_id}/declarations", content: {}, health_unit_id: consultation.attendance.health_unit_id
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "clinical_documents" } ])
    get "/attendance/documents/#{id}"
    expect(response).to have_http_status(:ok)
  end

  it "replaces_document_id inválido → 422 invalid_content com field; id malformado → 404" do
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note", content: { type: "leave", days: 3 },
                                                                        replaces_document_id: SecureRandom.uuid
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_content", "field" => "replaces_document_id" } ])
    get "/attendance/documents/nao-e-uuid"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    get "/attendance/consultations/nao-e-uuid/documents"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end

  it "rascunho: só a autora lista (outro profissional 403 not_author)" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
    sign_in_as(doctor)
    get "/attendance/consultations/#{draft.id}/documents"
    expect([ response.status, json_body ]).to eq([ 200, { "items" => [] } ])
    sign_in_as(doctor!(unit))
    get "/attendance/consultations/#{draft.id}/documents"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])
  end

  it "listagem: documento digital traz o bloco do 19b (pending); o papel puro traz signature null" do
    signature_city!
    linked_certificate!(doctor.tap { |u| u.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF) })
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note", content: { type: "leave", days: 3 }
    digital = json_body
    expect(digital["issue_mode"]).to eq("digital")
    request = SignatureRequest.find_by!(document_type: "ClinicalDocument", document_id: digital["id"])
    json_post "/attendance/attendances/#{consultation.attendance_id}/declarations", content: {}, health_unit_id: consultation.attendance.health_unit_id
    paper = json_body
    get "/attendance/consultations/#{consultation.id}/documents"
    signatures = json_body["items"].to_h { |item| [ item["id"], item["signature"] ] }
    expect(signatures).to eq(digital["id"] => { "mode" => "pending", "request_id" => request.id })
    get "/attendance/consultations/#{consultation.id}/documents/status"
    expect(json_body["items"]).to eq([ { "id" => digital["id"], "status" => "issued", "signature_mode" => "pending" } ])
    expect(paper).to include("consultation_id" => nil, "signature" => nil) # a declaração do atendimento não é da consulta
  end

  it "a listagem não faz N+1: o número de consultas não cresce com os documentos" do
    sign_in_as(doctor)
    count_queries = lambda do
      queries = 0
      callback = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/) }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get "/attendance/consultations/#{consultation.id}/documents" }
      queries
    end
    json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note", content: { type: "leave", days: 3 }
    one = count_queries.call
    3.times { json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note", content: { type: "leave", days: 1 } }
    four = count_queries.call
    expect(json_body["items"].size).to eq(4)
    expect(json_body["items"].map { |item| item["signature"] }.uniq).to eq([ nil ])
    expect(four).to eq(one)
  end
end
