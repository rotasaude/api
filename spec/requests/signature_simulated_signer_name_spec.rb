require "rails_helper"

# api#55, contra o signer real: (1) o PDF assinado de uma consulta curta tem
# uma página, com o conteúdo e o rodapé na 1ª; (2) no PSC simulado o e-CPF de
# teste leva no CN o nome do profissional do CPF (cadastro de profissional da
# cidade), no formato ICP do DevPki, e o rodapé do PDF assinado traz esse nome.
RSpec.describe "PSC simulado: nome do titular e PDF assinado", :signer, type: :request do
  before do
    stub_psc_mock!
    ciap2_release!; cid10_release!; sigtap_release!
  end
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit).tap { |user| user.professional.update!(professional_name: "Helena Duarte Moreira") } }
  let(:cpf) { SignatureHelpers::DOCTOR_CPF }
  def body = JSON.parse(response.body)
  def pages(bytes) = PDF::Reader.new(StringIO.new(bytes)).pages.map { |page| page.text.gsub(/\s+/, " ") }

  def approve!(path, params)
    post path, params: params, as: :json
    url = body.fetch("authorize_url")
    state = URI.decode_www_form(URI(url).query).to_h.fetch("state")
    post "/signature/oauth/callback", params: { state: state, code: authorize_and_approve!(url, key: "simulated") }, as: :json
    expect(response).to have_http_status(:ok)
  end

  it "vincula e assina pelo PSC simulado: CN com o nome do profissional; PDF de 1 página com o nome no rodapé" do
    sign_in_as(doctor).update!(mfa_verified_at: Time.current)
    approve!("/signature/certificates/link", { provider: "simulated", return_to: "/conta/assinatura" })
    certificate = SignerCertificate.active.find_by!(user_id: doctor.id)
    info = Signatures::CertificateInfo.parse(Base64.strict_decode64(certificate.certificate_der))
    expect(info.certificate.subject.to_a.find { |key, _value, _type| key == "CN" }[1].force_encoding("UTF-8"))
      .to eq("HELENA DUARTE MOREIRA:#{cpf}")
    expect([ info.holder_name, info.cpf ]).to eq([ "HELENA DUARTE MOREIRA", cpf ])

    approve!("/signature/sessions", { return_to: "/fila" })
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1, social_name: "Mariana"))
    request = signature_request!(consultation, author: doctor)
    expect(ApplicationRecord.transaction { Signatures::SignPending.call(request_id: request.id) }).to eq(:signed)

    get "/signature/signatures/#{request.reload.signature.id}/pdf"
    expect(response).to have_http_status(:ok)
    texts = pages(response.body)
    expect(texts.size).to eq(1)
    expect(texts.first).to include("Registro de atendimento individual", "Mariana",
                                   "assinado digitalmente por HELENA DUARTE MOREIRA", "simulada — sem validade jurídica")
    expect(Signatures::Signer.client.verify(kind: "pades", signature: request.signature.signed_pdf_bytes).status).to eq("valid")
  end
end
