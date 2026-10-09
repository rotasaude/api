# spec/requests/signature_reading_spec.rb
require "rails_helper"

# Contrato §2 e §6 (spec §5 validação, §7 exportação, §9 impresso; NGS2.03.01,
# 06.03): o modo de cada documento, o conteúdo assinado com trilha, a
# revalidação, o PDF, o pacote e o impresso. Leitura pelas regras revisadas do
# 19a (contrato §13, "Ajuste vindo do 19a"): autora sempre; outro profissional
# em contexto ou por abertura; municipal_admin só o conteúdo, com step-up.
# `simulated` sempre booleano (R5).
RSpec.describe "Leitura da assinatura", type: :request do
  before do
    signature_city!
    ciap2_release!; cid10_release!; sigtap_release!
    stub_psc!
    @signer = stub_signer!
  end

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit) }
  let(:admin) do
    staff_with("adm-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  def body = JSON.parse(response.body)
  def viewed = DomainEvent.where(name: "clinical_record.viewed").order(:created_at, :id)
  def step_up!(user) = sign_in_as(user).update!(mfa_verified_at: Time.current)

  def in_context!(consultation) = consulting_attendance!(unit, citizen: consultation.attendance.citizen, doctor: doctor)
  def text_of(bytes) = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join(" ").gsub(/\s+/, " ")

  def zip_entries(bytes)
    entries = {}
    Zip::InputStream.open(StringIO.new(bytes)) do |zip|
      while (entry = zip.get_next_entry)
        entries[entry.name] = zip.read
      end
    end
    entries
  end

  it "o bloco signature na consulta e no adendo: manual, pending e digital" do
    manual = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    pending = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
    pending_request = signature_request!(pending, author: doctor, reason_code: "no_session")
    returned = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(5))
    returned_request = signature_request!(returned, author: doctor, status: "returned_to_paper", reason_code: "feature_disabled")
    signed = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(3))
    signature = sign_document!(signed, author: doctor)
    addendum = Consultations::AddAddendum.call(consultation: signed, by: doctor, reason: "exame adicional pedido", text: "UM").payload[:addendum]

    expect(Consultations::Json.consultation(manual)[:signature]).to eq(mode: "manual")
    expect(Consultations::Json.consultation(pending)[:signature]).to eq(mode: "pending", request_id: pending_request.id, reason_code: "no_session")
    expect(Consultations::Json.consultation(returned)[:signature])
      .to eq(mode: "manual", request_id: returned_request.id, reason_code: "feature_disabled")
    json = Consultations::Json.consultation(signed.reload)
    expect(json[:signature]).to eq(mode: "digital", request_id: signature.signature_request_id, signature_id: signature.id,
                                   signed_at: signature.signed_at.iso8601, signer_name: doctor.professional.professional_name,
                                   verification: "valid", simulated: false)
    # Autora com certificado ativo: o pedido do adendo nasce no próprio adendo (Task 20).
    addendum_request = SignatureRequest.find_by!(document_type: "ConsultationAddendum", document_id: addendum.id)
    expect(json[:addenda].sole[:signature]).to eq(mode: "pending", request_id: addendum_request.id)
    expect(Consultations::Json.addendum(addendum)[:signature]).to eq(mode: "pending", request_id: addendum_request.id)
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(4))
    expect(Consultations::Json.consultation(draft)).not_to have_key(:signature)
  end

  it "conteúdo assinado: forma do contrato, trilha, revalidação e evento; fora de contexto 403 opening_required" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    signature = sign_document!(consultation, author: doctor)
    in_context!(consultation)
    sign_in_as(doctor)
    get "/signature/signatures/#{signature.id}"
    expect(response).to have_http_status(:ok)
    expect(body.keys).to match_array(%w[id document_type document_id signed_at signer_name signer_cpf_masked policy provider
                                        simulated verification verification_reasons verified_at content])
    expect(body).to include("document_type" => "consultation", "document_id" => consultation.id, "policy" => "AD-RB",
                            "signer_cpf_masked" => "***.982.247-**", "verification" => "valid", "provider" => "vidaas",
                            "simulated" => false, "signer_name" => doctor.professional.professional_name)
    expect(body["content"]).to eq(JSON.parse(signature.canonical_json))
    expect(viewed.pluck(:payload).last).to include("patient_id" => consultation.patient_id, "access" => "author")

    @signer.revoked_serials << signature.signer_certificate.serial_number
    json_post "/signature/signatures/#{signature.id}/verify", {}
    expect(body.keys).to include("provider", "simulated")
    expect(body.values_at("verification", "verification_reasons")).to eq([ "invalid", [ "certificate_revoked" ] ])
    expect(DomainEvent.where(name: "signature.verified").pluck(:payload).last)
      .to eq("signature_id" => signature.id, "verification" => "invalid")
    expect(signature.reload.canonical_sha256).to eq(Digest::SHA256.hexdigest(signature.canonical_json)) # o registro não muda

    @signer.unavailable = true
    get "/signature/signatures/#{signature.id}"
    expect(body["verification"]).to eq("invalid") # o guardado, sem cair

    sign_in_as(signer_doctor!(create_unit("UBS Dois"), cpf: SignatureHelpers::OTHER_CPF))
    trails = viewed.count
    %W[/signature/signatures/#{signature.id} /signature/signatures/#{signature.id}/pdf /signature/signatures/#{signature.id}/package].each do |path|
      get path
      expect([ response.status, body["error"] ]).to eq([ 403, "opening_required" ]), path
    end
    json_post "/signature/signatures/#{signature.id}/verify", {}
    expect([ response.status, body["error"] ]).to eq([ 403, "opening_required" ])
    expect(viewed.count).to eq(trails) # recusa não deixa trilha
  end

  it "profissional e admin ao mesmo tempo: grant de profissional primeiro; fora de contexto, show cai no administrativo e PDF 403" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    signature = sign_document!(consultation, author: doctor)
    both = signer_doctor!(create_unit("UBS Dois"), cpf: SignatureHelpers::OTHER_CPF)
    Membership.create!(user: both, role: "municipal_admin", granted_at: Time.current)

    step_up!(both)
    get "/signature/signatures/#{signature.id}"
    expect(response).to have_http_status(:ok)
    expect(viewed.pluck(:payload).last).to include("user_id" => both.id, "access" => "administrative")
    expect(ClinicalRecordAdministrativeRead.where(user_id: both.id).count).to eq(1)
    trails = viewed.count
    get "/signature/signatures/#{signature.id}/pdf"
    expect([ response.status, body["error"] ]).to eq([ 403, "opening_required" ])
    expect(viewed.count).to eq(trails)

    ClinicalRecordOpening.create!(patient: consultation.patient, user: both, reason_code: "case_review",
                                  created_at: Time.current, expires_at: 30.minutes.from_now)
    get "/signature/signatures/#{signature.id}"
    expect(response).to have_http_status(:ok)
    expect(viewed.pluck(:payload).last).to include("user_id" => both.id, "access" => "justified")
    expect(ClinicalRecordAdministrativeRead.where(user_id: both.id).count).to eq(1) # o grant de profissional veio primeiro
  end

  it "verify recusado pelo signer: devolve o guardado e registra só o id e o código" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    signature = sign_document!(consultation, author: doctor)
    allow(@signer).to receive(:verify).and_raise(Signatures::Signer::Rejected.new("invalid_request"))
    sign_in_as(doctor)
    log = capture_log { json_post "/signature/signatures/#{signature.id}/verify", {} }
    expect([ response.status, body["verification"] ]).to eq([ 200, "valid" ])
    expect(log).to include("signature_id=#{signature.id} code=invalid_request")
    expect(log).not_to include(SignatureHelpers::DOCTOR_CPF)
  end

  it "a autora lê sem contexto (trilha author); outro profissional lê com abertura justificada (trilha justified)" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    signature = sign_document!(consultation, author: doctor)
    sign_in_as(doctor)
    get "/signature/signatures/#{signature.id}"
    expect(response).to have_http_status(:ok)
    get "/signature/signatures/#{signature.id}/pdf"
    expect(response).to have_http_status(:ok)
    expect(viewed.pluck(:payload).map { |p| p["access"] }).to eq(%w[author author])

    nurse = signer_doctor!(create_unit("UBS Dois"), cpf: SignatureHelpers::OTHER_CPF)
    ClinicalRecordOpening.create!(patient: consultation.patient, user: nurse, reason_code: "case_review",
                                  created_at: Time.current, expires_at: 30.minutes.from_now)
    sign_in_as(nurse)
    get "/signature/signatures/#{signature.id}/package"
    expect(response).to have_http_status(:ok)
    expect(viewed.pluck(:payload).last).to include("user_id" => nurse.id, "access" => "justified", "reason_code" => "case_review")
  end

  it "municipal_admin: só o conteúdo, com step-up, linha administrativa e trilha administrative; PDF, pacote e verify 403" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    signature = sign_document!(consultation, author: doctor)
    sign_in_as(admin).update!(mfa_verified_at: 6.minutes.ago)
    get "/signature/signatures/#{signature.id}"
    expect([ response.status, body["error"] ]).to eq([ 401, "mfa_required" ])
    expect(ClinicalRecordAdministrativeRead.count).to eq(0)

    step_up!(admin)
    get "/signature/signatures/#{signature.id}"
    expect(response).to have_http_status(:ok)
    expect(body["content"]).to eq(JSON.parse(signature.canonical_json))
    expect(ClinicalRecordAdministrativeRead.sole).to have_attributes(user_id: admin.id, patient_id: consultation.patient_id,
                                                                     consultation_id: consultation.id)
    expect(viewed.pluck(:payload).last).to eq("patient_id" => consultation.patient_id, "user_id" => admin.id,
                                              "access" => "administrative", "reason_code" => nil,
                                              "consultation_id" => consultation.id)
    events = viewed.count
    %W[/signature/signatures/#{signature.id}/pdf /signature/signatures/#{signature.id}/package].each do |path|
      get path
      expect([ response.status, body["error"] ]).to eq([ 403, "missing_role" ]), path
    end
    json_post "/signature/signatures/#{signature.id}/verify", {}
    expect([ response.status, body["error"] ]).to eq([ 403, "missing_role" ])
    expect([ viewed.count, ClinicalRecordAdministrativeRead.count ]).to eq([ events, 1 ])
  end

  it "id inexistente 404 not_found" do
    sign_in_as(doctor)
    get "/signature/signatures/#{SecureRandom.uuid}"
    expect([ response.status, body["error"] ]).to eq([ 404, "not_found" ])
    get "/signature/signatures/nao-e-uuid/pdf"
    expect([ response.status, body["error"] ]).to eq([ 404, "not_found" ])
  end

  it "PDF assinado e pacote .zip (JSON + .p7s), sem cache; visíveis com o interruptor desligado" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    signature = sign_document!(consultation, author: doctor)
    in_context!(consultation)
    signature_city!(enabled: false)
    sign_in_as(doctor)
    get "/signature/signatures/#{signature.id}/pdf"
    expect([ response.status, response.media_type ]).to eq([ 200, "application/pdf" ])
    expect(response.body.b).to eq(signature.signed_pdf_bytes.b)
    expect(response.headers["Cache-Control"]).to include("no-store")
    get "/signature/signatures/#{signature.id}/package"
    expect(response.media_type).to eq("application/zip")
    expect(response.headers["Cache-Control"]).to include("no-store")
    entries = zip_entries(response.body)
    expect(entries.keys).to eq(%w[document.json document.json.p7s])
    expect(entries["document.json"].force_encoding("UTF-8")).to eq(signature.canonical_json)
    expect(entries["document.json.p7s"].b).to eq(signature.cades_bytes.b)
    expect(response.headers["Content-Disposition"]).to include("documento-assinado.zip")
    expect(response.headers["Content-Disposition"]).not_to include(consultation.patient.display_name.to_s)
  end

  it "PSC simulado: simulated true no bloco e no payload, aviso no pacote e no impresso" do
    stub_psc_mock!
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    signature = sign_document!(consultation, author: doctor, provider: "simulated")
    expect(Consultations::Json.consultation(consultation.reload)[:signature]).to include(mode: "digital", simulated: true)
    sign_in_as(doctor)
    get "/signature/signatures/#{signature.id}"
    expect(body.values_at("provider", "simulated")).to eq([ "simulated", true ])
    json_post "/signature/signatures/#{signature.id}/verify", {}
    expect(body.values_at("provider", "simulated")).to eq([ "simulated", true ])
    get "/signature/signatures/#{signature.id}/package"
    entries = zip_entries(response.body)
    expect(entries.keys).to eq(%w[document.json document.json.p7s AVISO-ASSINATURA-SIMULADA.txt])
    expect(entries["AVISO-ASSINATURA-SIMULADA.txt"].force_encoding("UTF-8"))
      .to include("Assinatura simulada — sem validade jurídica. PSC simulado de desenvolvimento.")
    expect(response.headers["Content-Disposition"]).to include("documento-assinado-simulado.zip")

    Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "exame adicional pedido", text: "Adendo")
    get "/attendance/consultations/#{consultation.id}/print"
    expect(text_of(response.body)).to include("Consulta: assinada digitalmente (simulada — sem validade jurídica) por")
  end

  it "prontuário desligado: 403 do clinical_record; recepção: 403" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    signature = sign_document!(consultation, author: doctor)
    sign_in_as(reception!)
    get "/signature/signatures/#{signature.id}"
    expect([ response.status, body["error"] ]).to eq([ 403, "missing_role" ])
    Platform::Features.set!(city: City.find_by(slug: TEST_CITY_A.slug), key: "clinical_record", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(doctor)
    get "/signature/signatures/#{signature.id}"
    expect(body).to eq("error" => "feature_disabled", "feature" => "clinical_record")
  end

  it "impresso: assinado → o PAdES; com adendo → seção Assinaturas; sem pedido nenhum → o impresso do 19a" do
    plain = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    in_context!(plain)
    sign_in_as(doctor)
    get "/attendance/consultations/#{plain.id}/print"
    expect(text_of(response.body)).to include("Assinatura e carimbo")
    expect(text_of(response.body)).not_to include("Assinaturas")

    signed = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
    signature = sign_document!(signed, author: doctor)
    in_context!(signed)
    get "/attendance/consultations/#{signed.id}/print"
    expect(response.body.b).to eq(signature.signed_pdf_bytes.b)

    # Sem certificado ativo o adendo fica no papel (com ele, o pedido nasceria no adendo — Task 20).
    SignerCertificate.where(user_id: doctor.id).update_all(status: "unlinked")
    Consultations::AddAddendum.call(consultation: signed, by: doctor, reason: "exame adicional pedido", text: "Adendo sem assinatura")
    expect(SignatureRequest.where(document_type: "ConsultationAddendum")).to be_empty
    get "/attendance/consultations/#{signed.id}/print"
    text = text_of(response.body)
    expect(text).to include("Assinaturas", "Consulta: assinada digitalmente por", "validação válida", "Adendo de",
                            "sem assinatura digital", "Assinatura e carimbo")
  end

  it "impresso: consulta digital sem adendo mas revalidação inválida → impresso do 19a com o estado (R21)" do
    signed = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    signature = sign_document!(signed, author: doctor)
    @signer.revoked_serials << signature.signer_certificate.serial_number
    sign_in_as(doctor)
    get "/attendance/consultations/#{signed.id}/print"
    expect(response.body.b).not_to eq(signature.signed_pdf_bytes.b)
    text = text_of(response.body)
    expect(text).to include("Assinaturas", "Consulta: assinada digitalmente por", "validação inválida", "Assinatura e carimbo")
    expect(signature.reload.last_verification).to eq("invalid")
  end

  it "impresso com todas as partes digitais: seção Assinaturas sem espaço para assinar à mão" do
    signed = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    sign_document!(signed, author: doctor)
    addendum = Consultations::AddAddendum.call(consultation: signed, by: doctor, reason: "exame adicional pedido",
                                               text: "Adendo assinado").payload[:addendum]
    sign_document!(addendum, author: doctor)
    sign_in_as(doctor)
    get "/attendance/consultations/#{signed.id}/print"
    text = text_of(response.body)
    expect(text).to include("Assinaturas", "Consulta: assinada digitalmente por", "Adendo de")
    expect(text).not_to include("Assinatura e carimbo")
    expect(text).not_to include("assinar à mão")
  end
end
