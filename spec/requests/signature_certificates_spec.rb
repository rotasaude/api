# spec/requests/signature_certificates_spec.rb
require "rails_helper"

# Contrato §3–§4 (spec §5, vínculo; NGS2.01.02/02.02): localizar por CPF em
# cada PSC habilitado, vincular com step-up e PKCE, conferir CPF, validade, uso
# e revogação (signer, contrato D1); desvincular com step-up. Review Focus 4: callback nas bordas.
RSpec.describe "Vínculo do certificado", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before do
    signature_city!
    stub_psc!(%w[vidaas birdid])
    @signer = stub_signer!
  end

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit) }
  let(:cpf) { SignatureHelpers::DOCTOR_CPF }
  def body = JSON.parse(response.body)

  def stepped_in(user = doctor) = sign_in_as(user).update!(mfa_verified_at: Time.current)

  def start_link(provider = "vidaas")
    post "/signature/certificates/link", params: { provider: provider, return_to: "/conta/assinatura" }, as: :json
    body.fetch("authorize_url")
  end

  def state_of(url) = URI.decode_www_form(URI(url).query).to_h.fetch("state")

  def callback(state, code: nil, error: nil)
    post "/signature/oauth/callback", params: { state: state, code: code, error: error }.compact, as: :json
  end

  def token_calls(key = "vidaas") = fake_psc(key).log.count { |entry| entry == [ "POST", "/v0/oauth/token" ] }

  it "localiza o CPF do profissional em cada PSC habilitado; PSC fora do ar vai para unavailable" do
    sign_in_as(doctor)
    fake_psc("birdid").absent_cpfs << cpf
    post "/signature/certificates/discover", as: :json
    expect(body).to eq("providers" => [ { "provider" => "vidaas", "found" => true }, { "provider" => "birdid", "found" => false } ],
                       "unavailable" => [])
    fake_psc("birdid").failures << 503
    post "/signature/certificates/discover", as: :json
    expect(body).to eq("providers" => [ { "provider" => "vidaas", "found" => true } ], "unavailable" => [ "birdid" ])
  end

  it "vincula: step-up, URL com PKCE e CPF, callback grava o certificado; GET current" do
    sign_in_as(doctor)
    post "/signature/certificates/link", params: { provider: "vidaas" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 401, "mfa_required" ])
    stepped_in
    post "/signature/certificates/link", params: { provider: "safeid" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_provider" ])

    url = start_link
    query = URI.decode_www_form(URI(url).query).to_h
    expect(query).to include("scope" => "single_signature", "code_challenge_method" => "S256", "login_hint" => cpf)
    code = authorize_and_approve!(url)
    callback(state_of(url), code: code)
    expect(response).to have_http_status(:ok)
    expect(body.slice("purpose", "return_to")).to eq("purpose" => "link", "return_to" => "/conta/assinatura")
    leaf = fake_psc.leaf(cpf)
    expect(body["result"]).to include("provider" => "vidaas", "issuer" => Signatures::CertificateInfo.new(fake_psc.leaf(cpf).certificate).issuer_name,
                                      "serial_number" => leaf.serial_hex, "status" => "active")
    expect(body["result"].keys).to match_array(%w[id provider issuer serial_number not_after status expires_in_days])
    expect(body["result"]["expires_in_days"]).to be_between(360, 366)
    expect(response.body).not_to include(*fake_psc.issued_tokens)

    get "/signature/certificates/current"
    expect(body["serial_number"]).to eq(leaf.serial_hex)
    expect(DomainEvent.where(name: "signature.certificate_linked").sole.payload.keys).to match_array(%w[certificate_id user_id provider])
  end

  it "mesmo serial do mesmo PSC: nada muda; outro serial: o anterior vira replaced e a sessão ativa cai" do
    stepped_in
    url = start_link
    callback(state_of(url), code: authorize_and_approve!(url))
    first = SignerCertificate.active.find_by!(user_id: doctor.id)
    session = signature_session!(doctor, certificate: first)

    url = start_link
    callback(state_of(url), code: authorize_and_approve!(url))
    expect(response).to have_http_status(:ok)
    expect(SignerCertificate.where(user_id: doctor.id).pluck(:id)).to eq([ first.id ])
    expect(session.reload.status).to eq("active")

    fake_psc.certificate_overrides[cpf] = test_pki.issue(cpf: cpf, name: "RENOVADO")
    url = start_link
    callback(state_of(url), code: authorize_and_approve!(url))
    expect(response).to have_http_status(:ok)
    expect([ first.reload.status, session.reload.status ]).to eq(%w[replaced revoked])
    expect(SignerCertificate.active.find_by!(user_id: doctor.id).serial_number).to eq(fake_psc.leaf(cpf).serial_hex)
    expect(DomainEvent.where(name: "signature.certificate_linked").count).to eq(2)
  end

  it "callback nas bordas: reuso, outro usuário, vencido, recusado no celular, código já trocado (Review Focus 4)" do
    stepped_in
    url = start_link
    code = authorize_and_approve!(url)
    callback(state_of(url), code: code)
    callback(state_of(url), code: code)
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_state" ])
    expect(token_calls).to eq(1) # o mesmo código nunca é trocado duas vezes

    url = start_link
    other = signer_doctor!(create_unit("UBS Dois"), cpf: SignatureHelpers::OTHER_CPF)
    stepped_in(other)
    callback(state_of(url), code: authorize_and_approve!(url))
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_state" ])
    expect(body).not_to have_key("return_to") # o state de outro usuário não revela nada
    expect(SignerCertificate.where(user_id: other.id)).to be_empty

    stepped_in
    url = start_link
    code = authorize_and_approve!(url)
    travel 11.minutes do
      callback(state_of(url), code: code)
      expect([ response.status, body["error"], body["return_to"] ]).to eq([ 409, "authorization_expired", "/conta/assinatura" ])
    end

    url = start_link
    Net::HTTP.get_response(URI(url))
    fake_psc.decide!(state_of(url), approve: false)
    callback(state_of(url), error: "access_denied")
    expect([ response.status, body["error"], body["return_to"] ]).to eq([ 403, "authorization_denied", "/conta/assinatura" ])
    callback(state_of(url), error: "access_denied")
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_state" ]) # a recusa consome o state

    url = start_link
    code = authorize_and_approve!(url)
    Signatures::Psc::Client.for("vidaas").exchange(code: code, verifier: "qualquer", redirect_uri: "x") rescue nil # o falso apaga o código no 1º uso
    callback(state_of(url), code: code)
    expect([ response.status, body["error"] ]).to eq([ 409, "authorization_expired" ])

    url = start_link
    authorize_and_approve!(url)
    callback(state_of(url))
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_state" ])
    callback("adulterado", code: "x")
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_state" ])
  end

  it "certificado de outro CPF, vencido, sem não repúdio, revogado ou de cadeia desconhecida não é vinculado" do
    stepped_in
    {
      test_pki.issue(cpf: SignatureHelpers::OTHER_CPF, name: "OUTRA PESSOA") => "certificate_cpf_mismatch",
      test_pki.issue(cpf: cpf, name: "VENCIDO", not_before: 2.years.ago, not_after: 1.day.ago) => "certificate_expired",
      test_pki.issue(cpf: cpf, name: "SEM NR", key_usage: "digitalSignature") => "certificate_not_found"
    }.each do |leaf, error|
      fake_psc.certificate_overrides[cpf] = leaf
      url = start_link
      callback(state_of(url), code: authorize_and_approve!(url))
      expect([ response.status, body["error"], body["return_to"] ]).to eq([ 422, error, "/conta/assinatura" ]), error
    end
    leaf = test_pki.issue(cpf: cpf, name: "REVOGADO")
    fake_psc.certificate_overrides[cpf] = leaf
    @signer.revoked_serials << leaf.serial_hex # o check do signer diz invalid/certificate_revoked
    url = start_link
    callback(state_of(url), code: authorize_and_approve!(url))
    expect([ response.status, body["error"] ]).to eq([ 422, "certificate_revoked" ])
    expect(SignerCertificate.where(user_id: doctor.id)).to be_empty
    expect(@signer.calls).to include(:check)

    leaf = test_pki.issue(cpf: cpf, name: "CADEIA DESCONHECIDA")
    fake_psc.certificate_overrides[cpf] = leaf
    @signer.untrusted_serials << leaf.serial_hex
    url = start_link
    callback(state_of(url), code: authorize_and_approve!(url))
    expect([ response.status, body["error"] ]).to eq([ 422, "certificate_untrusted" ])
  end

  it "LCR fora do ar no vínculo: aceita e guarda o motivo; signer fora do ar: 503 signer_unavailable" do
    stepped_in
    @signer.unavailable = true
    url = start_link
    callback(state_of(url), code: authorize_and_approve!(url))
    expect([ response.status, body["error"] ]).to eq([ 503, "signer_unavailable" ])
    @signer.unavailable = false
    @signer.revocation_unavailable = true
    url = start_link
    callback(state_of(url), code: authorize_and_approve!(url))
    expect(response).to have_http_status(:ok)
    expect(SignerCertificate.active.find_by(user_id: doctor.id))
      .to have_attributes(link_check_status: "indeterminate", link_check_reasons: [ "revocation_unavailable" ])
  end

  it "PSC fora do ar na troca do código: 503 provider_unavailable, e o state já foi consumido" do
    stepped_in
    url = start_link
    code = authorize_and_approve!(url)
    fake_psc.failures << 503
    callback(state_of(url), code: code)
    expect([ response.status, body["error"], body["return_to"] ]).to eq([ 503, "provider_unavailable", "/conta/assinatura" ])
    callback(state_of(url), code: code)
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_state" ])
    expect(SignerCertificate.where(user_id: doctor.id)).to be_empty
  end

  it "desvincula com step-up; a sessão ativa cai; sem certificado: 404" do
    certificate = linked_certificate!(doctor)
    session = signature_session!(doctor, certificate: certificate)
    sign_in_as(doctor)
    delete "/signature/certificates/current", as: :json
    expect(response).to have_http_status(:unauthorized)
    stepped_in
    delete "/signature/certificates/current", as: :json
    expect(response).to have_http_status(:no_content)
    expect([ certificate.reload.status, session.reload.status ]).to eq(%w[unlinked revoked])
    expect(DomainEvent.where(name: "signature.certificate_unlinked").sole.payload.keys).to match_array(%w[certificate_id user_id provider])
    get "/signature/certificates/current"
    expect([ response.status, body["error"] ]).to eq([ 404, "certificate_not_linked" ])
    delete "/signature/certificates/current", as: :json
    expect(response).to have_http_status(:not_found)
  end

  it "interruptor desligado: 403 feature_disabled; recepção: 403 missing_role; sem CPF no perfil: 409" do
    signature_city!(enabled: false)
    sign_in_as(doctor)
    get "/signature/certificates/current"
    expect([ response.status, body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "digital_signature" } ])
    signature_city!
    sign_in_as(reception!)
    post "/signature/certificates/discover", as: :json
    expect([ response.status, body["error"] ]).to eq([ 403, "missing_role" ])
    doctor.professional.update!(cpf: nil)
    sign_in_as(doctor)
    post "/signature/certificates/discover", as: :json
    expect([ response.status, body["error"] ]).to eq([ 409, "professional_cpf_missing" ])
    stepped_in
    post "/signature/certificates/link", params: { provider: "vidaas", return_to: "/conta" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 409, "professional_cpf_missing" ])
  end

  describe "PSC simulado (interruptor signature_psc_mock; ADR 0032, revisão)" do
    it "ligado: discover lista só o simulated" do
      stub_psc_mock!
      sign_in_as(doctor)
      post "/signature/certificates/discover", as: :json
      expect(body).to eq("providers" => [ { "provider" => "simulated", "found" => true } ], "unavailable" => [])
    end

    it "vincular com simulated: ligado funciona e grava provider simulated; desligado 422 invalid_provider" do
      stepped_in
      post "/signature/certificates/link", params: { provider: "simulated", return_to: "/conta" }, as: :json
      expect([ response.status, body["error"] ]).to eq([ 422, "invalid_provider" ])

      stub_psc_mock!
      url = start_link("simulated")
      expect(url).to start_with(SignatureHelpers::PSC_BASES.fetch("simulated"))
      callback(state_of(url), code: authorize_and_approve!(url, key: "simulated"))
      expect(response).to have_http_status(:ok)
      expect(body["result"]["provider"]).to eq("simulated")
      expect(SignerCertificate.active.find_by!(user_id: doctor.id).provider).to eq("simulated")
      post "/signature/certificates/link", params: { provider: "vidaas", return_to: "/conta" }, as: :json
      expect([ response.status, body["error"] ]).to eq([ 422, "invalid_provider" ])
    end
  end
end
