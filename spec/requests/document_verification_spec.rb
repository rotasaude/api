# spec/requests/document_verification_spec.rb
require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_include, :include

# Spec §6; contrato §7; ADR 0033 (Invariantes): a página pública mostra
# autenticidade, profissional, unidade, iniciais e ano de nascimento,
# situação e modo — nunca CID, medicamento, dias de afastamento ou CPF. O
# código curto digitado por gente (Review Focus 3) e o limite por IP.
RSpec.describe "Conferência pública de documento", type: :request do
  before do
    documents_city!; ciap2_release!; cid10_release!; sigtap_release!; import_test_catalog!
    Rails.cache.clear
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
  end

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(1) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen) }
  let(:json_headers) { { "Accept" => "application/json" } }

  def issue!(kind, content) = ClinicalDocuments::Issue.call(kind: kind, content: content, by: doctor, consultation: consultation).payload[:document]
  def sick_note! = issue!("sick_note", { "type" => "leave", "days" => 5, "cid10" => { "code" => "I10" }, "cid_authorized" => true })

  it "pelo token: só o permitido; nada clínico nem pessoal, em JSON e em HTML" do
    document = sick_note!
    get "/v/#{document.verification_token}", headers: json_headers
    body = JSON.parse(response.body)
    expect(body).to eq("kind" => "sick_note", "issued_at" => document.issued_at.iso8601,
                       "professional" => { "name" => doctor.professional.professional_name,
                                           "council" => "CRM-PR #{doctor.professional.registration_number}" },
                       "unit" => unit.name, "patient" => { "initials" => "M.A.S.", "birth_year" => Date.iso8601(citizen.birth_date).year },
                       "status" => "valid", "mode" => "paper", "simulated" => false)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    get "/v/#{document.verification_token}"
    expect(response.media_type).to eq("text/html")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    [ response.body, body.to_json ].each do |text|
      expect(text).not_to include("I10", "Hipertensão", "5 dia", citizen.cpf, "Maria Aparecida")
    end
    expect(DocumentVerificationLookup.last).to have_attributes(clinical_document_id: document.id, via: "token", outcome: "found")
  end

  it "receita: nenhum medicamento na página; cancelado mostra cancelado e quando" do
    document = issue!("prescription", { "items" => [ { "catalog_item" => { "id" => catalog_item(268_856).id }, "quantity" => 30,
                                                       "quantity_unit" => "comprimido", "route" => "oral",
                                                       "dosage_instructions" => "1 comprimido pela manhã" } ] })
    document.update!(status: "cancelled", cancel_reason: "Emitido por engano aqui", cancelled_at: Time.current, cancelled_by_user_id: doctor.id)
    get "/v/#{document.verification_token}", headers: json_headers
    expect(JSON.parse(response.body)).to include("status" => "cancelled", "cancelled_at" => document.cancelled_at.iso8601)
    expect(response.body).not_to include("LOSARTANA")
    get "/v/#{document.verification_token}"
    expect(response.body).to include("Cancelado").and(not_include("LOSARTANA"))
  end

  it "código digitado: caixa, hífen e espaço tolerados; ano errado, ano com 2 dígitos ou código inexistente → o mesmo 404" do
    document = sick_note!
    year = Date.iso8601(citizen.birth_date).year
    typed = ClinicalDocuments::Codes.display(document.short_code).downcase.sub("-", " - ")
    json_post "/v/lookup", short_code: typed, birth_year: year
    expect(JSON.parse(response.body)["status"]).to eq("valid")
    [ [ typed, year + 1 ], [ typed, year % 100 ], [ typed, "0#{year}" ], [ typed, "#{year}.0" ], [ typed, year.to_f ],
      [ "AAAAA-AAAAA", year ], [ "", "" ] ].each do |code, birth|
      json_post "/v/lookup", short_code: code, birth_year: birth
      expect([ response.status, JSON.parse(response.body) ]).to eq([ 404, { "error" => "not_found" } ])
    end
    expect(DocumentVerificationLookup.where(outcome: "not_found").count).to eq(7)
  end

  it "o código de outra cidade não existe aqui" do
    document = sick_note!
    create(:city, slug: TEST_CITY_B.slug, status: "active", database_url: city_database_url(TEST_CITY_B_DATABASE))
    json_post "/v/lookup", { short_code: document.short_code, birth_year: Date.iso8601(citizen.birth_date).year }
    expect(response).to have_http_status(:ok)
    post "/v/lookup", params: { short_code: document.short_code, birth_year: Date.iso8601(citizen.birth_date).year }.to_json,
                      headers: { "CONTENT_TYPE" => "application/json", "HOST" => "#{TEST_CITY_B.slug}.rotasaude.app" }
    expect(response).to have_http_status(:not_found)
  end

  it "o 11º palpite do mesmo IP em 10 minutos → 429; nada da pessoa no log" do
    log = capture_log do
      10.times { json_post "/v/lookup", short_code: "AAAAA-AAAAA", birth_year: 1980 }
      json_post "/v/lookup", short_code: "AAAAA-AAAAA", birth_year: 1980
    end
    expect([ response.status, JSON.parse(response.body) ]).to eq([ 429, { "error" => "rate_limited" } ])
    expect(log).not_to include("AAAAA", "1980")
  end

  it "digital assinado: status valid, simulated, PDF assinado baixável; aguardando assinatura antes" do
    stub_psc!; stub_signer!; signature_city!
    doctor.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF)
    linked_certificate!(doctor, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
    document = sick_note!
    get "/v/#{document.verification_token}", headers: json_headers
    expect(JSON.parse(response.body)).to include("status" => "awaiting_signature", "mode" => "digital")
    get "/v/#{document.verification_token}/signed.pdf"
    expect(response).to have_http_status(:not_found)
    signature = sign_document!(document, author: doctor)
    get "/v/#{document.verification_token}", headers: json_headers
    body = JSON.parse(response.body)
    expect(body).to include("status" => "valid", "mode" => "digital", "simulated" => false)
    expect(body["signed_pdf_url"]).to end_with("/v/#{document.verification_token}/signed.pdf")
    get "/v/#{document.verification_token}/signed.pdf"
    expect(response.body.b).to eq(signature.signed_pdf_bytes.b)
  end

  it "digital assinado e depois cancelado: cancelled, sem signed_pdf_url, PDF 404" do
    stub_psc!; stub_signer!; signature_city!
    doctor.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF)
    linked_certificate!(doctor, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
    document = sick_note!
    sign_document!(document, author: doctor)
    document.update!(status: "cancelled", cancel_reason: "Emitido por engano aqui", cancelled_at: Time.current, cancelled_by_user_id: doctor.id)
    get "/v/#{document.verification_token}", headers: json_headers
    body = JSON.parse(response.body)
    expect(body).to include("status" => "cancelled", "mode" => "digital", "cancelled_at" => document.cancelled_at.iso8601)
    expect(body).not_to have_key("signed_pdf_url")
    get "/v/#{document.verification_token}"
    expect(response.body).to include("Cancelado").and(not_include("signed.pdf"))
    get "/v/#{document.verification_token}/signed.pdf"
    expect(response).to have_http_status(:not_found)
  end

  it "declaração da recepção: sem perfil profissional, professional.name null; o e-mail nunca aparece" do
    reception = verifier!
    sign_in_as(reception)
    json_post "/attendance/attendances/#{consultation.attendance_id}/declarations", content: {}
    expect(response).to have_http_status(:created)
    document = ClinicalDocument.find(JSON.parse(response.body)["id"])
    get "/v/#{document.verification_token}", headers: json_headers
    body = JSON.parse(response.body)
    expect(body).to include("kind" => "attendance_declaration", "professional" => { "name" => nil, "council" => nil },
                            "status" => "valid", "mode" => "paper")
    json_text = response.body
    get "/v/#{document.verification_token}"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Profissional")
    [ json_text, response.body ].each { |text| expect(text).not_to include(reception.email_address, "@cidade.gov.br") }
  end

  it "token desconhecido → 404; o formulário existe" do
    get "/v/#{ClinicalDocuments::Codes.token}", headers: json_headers
    expect(response).to have_http_status(:not_found)
    get "/v"
    expect(response.body).to include("<form", "/v/lookup")
  end

  it "com o interruptor clinical_documents desligado a página pública segue respondendo" do
    document = sick_note!
    city = documents_city!(enabled: false)
    expect(Platform::Features.enabled?(city, "clinical_documents")).to be(false)
    get "/v/#{document.verification_token}", headers: json_headers
    expect(JSON.parse(response.body)).to include("status" => "valid")
    json_post "/v/lookup", short_code: document.short_code, birth_year: Date.iso8601(citizen.birth_date).year
    expect(response).to have_http_status(:ok)
    get "/v"
    expect(response).to have_http_status(:ok)
  end

  it "o 61º acesso ao token e o 31º ao PDF do mesmo IP em 10 minutos → 429" do
    token = ClinicalDocuments::Codes.token
    60.times { get "/v/#{token}", headers: json_headers }
    expect(response).to have_http_status(:not_found)
    get "/v/#{token}", headers: json_headers
    expect([ response.status, JSON.parse(response.body) ]).to eq([ 429, { "error" => "rate_limited" } ])
    30.times { get "/v/#{token}/signed.pdf" }
    expect(response).to have_http_status(:not_found)
    get "/v/#{token}/signed.pdf"
    expect([ response.status, JSON.parse(response.body) ]).to eq([ 429, { "error" => "rate_limited" } ])
  end
end
