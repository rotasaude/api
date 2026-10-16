require "rails_helper"

# Contrato §5 e B18 (conferência pública): a página /v do 19c aceita o laudo,
# como "Laudo laboratorial", sem resultado, sem CPF, sem nome e sem PDF
# público. D3: o /v/:token/signed.pdf também deixa trilha (4 linhas). Nota #6:
# o código curto pode repetir entre documentos e laudos — o ano desempata.
RSpec.describe "Conferência pública do laudo", type: :request do
  before { lab_city! }

  let(:provider) { lab_provider!(name: "Laboratório Municipal Central") }
  let(:lead) { lab_releaser!(provider, lead: true) }
  let(:req) { received_requisition!(provider: provider, exams: [ lab_exam!(provider: provider) ]) }

  def release!
    item = type!(req.items.first, { glicose: "98" })
    Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "advanced", totp: totp_for(lead), by: lead).payload.fetch(:report)
  end

  it "por token e por código + ano; sem valor; trilha sem dado pessoal" do
    report = release!
    get "/v/#{report.verification_token}", headers: { "Accept" => "application/json" }
    signer = lead.professional
    expect(json_body).to eq("kind" => "lab_report", "issued_at" => report.released_at.iso8601,
                            "professional" => { "name" => signer.professional_name,
                                                "council" => "CRBM-PR #{signer.registration_number}" },
                            "unit" => "Laboratório Municipal Central",
                            "patient" => { "initials" => Patients::Initials.call(req.patient.display_name),
                                           "birth_year" => req.patient.birth_date[0, 4].to_i },
                            "status" => "valid", "mode" => "advanced", "simulated" => false, "pdf_sha256" => report.pdf_sha256)
    # Sem valor, unidade, exame, CPF ou nome (o "98" do valor colide com o hex do hash; a igualdade acima já o exclui).
    expect(response.body).not_to include("mg/dL", "Glicose", req.patient.cpf, req.patient.display_name)
    year = req.patient.birth_date[0, 4]
    post "/v/lookup", params: { short_code: report.short_code, birth_year: year }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(json_body["kind"]).to eq("lab_report")
    get "/v/#{report.verification_token}"
    expect(response.body).to include("Laudo laboratorial", "Assinatura eletrônica avançada", report.pdf_sha256)
    expect(response.body).not_to include("mg/dL", "Glicose", req.patient.cpf, req.patient.display_name)
    get "/v/#{report.verification_token}/signed.pdf"
    expect(response).to have_http_status(:not_found)
    expect(DocumentVerificationLookup.where(lab_report_id: report.id).count).to eq(4)
    expect(DocumentVerificationLookup.where(lab_report_id: report.id).pluck(:clinical_document_id).uniq).to eq([ nil ])
  end

  it "ICP: aguardando assinatura (digital) enquanto pendente; retirado (withdrawn) não existe para fora" do
    city = stub_psc_mock!(City.find(Current.city.id))
    stub_signer!
    lead
    doctor = lab_releaser!(provider, council: "CRM").tap { |u| u.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF) }
    linked_certificate!(doctor, provider: "simulated", leaf: fake_psc("simulated").leaf(doctor.professional.cpf))
    item = type!(req.items.first, { glicose: "98" })
    report = Lab::Release.call(requisition: req, item_ids: [ item.id ], signature: "icp", totp: nil, by: doctor).payload.fetch(:report)
    get "/v/#{report.verification_token}", headers: { "Accept" => "application/json" }
    expect(json_body).to include("status" => "awaiting_signature", "mode" => "digital", "simulated" => false,
                                 "issued_at" => report.created_at.iso8601, "pdf_sha256" => nil)
    Platform::Features.set!(city: city, key: "digital_signature", enabled: false, maintainer: ledi_maintainer!)
    ApplicationRecord.transaction { Signatures::SignPending.call(request_id: report.signature_request.id) }
    expect(report.reload.status).to eq("withdrawn")
    get "/v/#{report.verification_token}", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:not_found)
    expect(DocumentVerificationLookup.order(:created_at).last).to have_attributes(outcome: "not_found", lab_report_id: nil)
  end

  it "código curto repetido entre documento clínico e laudo: o ano desempata; empate → não encontrado" do
    report = release!
    unit = create_unit("UBS #{SecureRandom.hex(2)}")
    doctor = doctor!(unit)
    citizen = verified_citizen!(1)
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    allow(ClinicalDocuments::Codes).to receive(:short_code).and_return(report.short_code)
    document = raw_document!(consultation: consultation)
    lab_year = req.patient.birth_date[0, 4].to_i
    doc_year = Date.iso8601(citizen.birth_date).year
    expect(lab_year).not_to eq(doc_year)

    lookup = ->(year) { ClinicalDocuments::Verification.lookup(short_code: report.short_code, birth_year: year.to_s) }
    expect(lookup.call(lab_year)).to eq(report)
    expect(lookup.call(doc_year)).to eq(document)
    expect(lookup.call(1900)).to be_nil

    allow(ClinicalDocuments::Verification).to receive(:birth_year_of).and_return(lab_year)
    expect(lookup.call(lab_year)).to be_nil
    expect(DocumentVerificationLookup.order(:created_at).last).to have_attributes(outcome: "not_found", clinical_document_id: nil,
                                                                                  lab_report_id: nil)
  end
end
