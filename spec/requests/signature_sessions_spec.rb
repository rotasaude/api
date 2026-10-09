# spec/requests/signature_sessions_spec.rb
require "rails_helper"

# Contrato §4 (spec §5, sessão do turno): uma aprovação no celular abre até
# 12 h de assinatura; o certificado é relido (renovado no PSC vira o ativo);
# o token nunca sai da cidade.
RSpec.describe "Sessão de assinatura", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before do
    signature_city!
    stub_psc!
    stub_signer!
  end

  let(:doctor) { signer_doctor!(create_unit) }
  let(:cpf) { SignatureHelpers::DOCTOR_CPF }
  def body = JSON.parse(response.body)

  def open_session!(key: "vidaas")
    post "/signature/sessions", params: { return_to: "/fila" }, as: :json
    url = body.fetch("authorize_url")
    state = URI.decode_www_form(URI(url).query).to_h.fetch("state")
    post "/signature/oauth/callback", params: { state: state, code: authorize_and_approve!(url, key: key) }, as: :json
    url
  end

  it "sem certificado vinculado: 409" do
    sign_in_as(doctor)
    post "/signature/sessions", params: { return_to: "/fila" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 409, "certificate_not_linked" ])
  end

  it "profissional sem CPF: 409 professional_cpf_missing" do
    linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    doctor.professional.update_columns(cpf: nil)
    sign_in_as(doctor)
    post "/signature/sessions", params: { return_to: "/fila" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 409, "professional_cpf_missing" ])
  end

  it "abre a sessão do turno: escopo, 12 h pedidas, sessão ativa, evento só com ids" do
    linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    sign_in_as(doctor)
    freeze_time do
      url = open_session!
      expect(URI.decode_www_form(URI(url).query).to_h).to include("scope" => "signature_session", "lifetime" => "43200")
      expect(response).to have_http_status(:ok)
      expect(body).to eq("purpose" => "session", "result" => { "expires_at" => 12.hours.from_now.iso8601 }, "return_to" => "/fila")
      get "/signature/sessions/current"
      expect(body).to eq("active" => true, "expires_at" => 12.hours.from_now.iso8601, "provider" => "vidaas")
    end
    expect(DomainEvent.where(name: "signature.session_opened").sole.payload.keys).to match_array(%w[session_id user_id provider])
    expect(response.body).not_to include(*fake_psc.issued_tokens)
  end

  it "o menor entre o que o PSC concede e o teto de 12 h" do
    linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    sign_in_as(doctor)
    freeze_time do
      fake_psc.forced_lifetime = 7 * 86_400
      open_session!
      expect(body.dig("result", "expires_at")).to eq(12.hours.from_now.iso8601)
      fake_psc.forced_lifetime = 3600
      open_session! # a anterior cai
      expect(body.dig("result", "expires_at")).to eq(1.hour.from_now.iso8601)
      expect(SignatureSession.where(user_id: doctor.id).pluck(:status)).to match_array(%w[revoked active])
    end
  end

  it "certificado renovado no PSC vira o ativo; o anterior, replaced" do
    old = linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    renewed = test_pki.issue(cpf: cpf, name: "PROFISSIONAL RENOVADO")
    fake_psc.certificate_overrides[cpf] = renewed
    sign_in_as(doctor)
    open_session!
    expect(old.reload.status).to eq("replaced")
    active = SignerCertificate.active.find_by(user_id: doctor.id)
    expect(active.serial_number).to eq(renewed.serial_hex)
    expect(SignatureSession.usable_for(doctor.id).signer_certificate_id).to eq(active.id)
  end

  it "vence sozinha; encerrar derruba; GET current diz inativa" do
    linked_certificate!(doctor, leaf: fake_psc.leaf(cpf))
    sign_in_as(doctor)
    open_session!
    travel 13.hours do
      get "/signature/sessions/current"
      expect(body).to eq("active" => false)
    end
    open_session!
    delete "/signature/sessions/current", as: :json
    expect(response).to have_http_status(:no_content)
    get "/signature/sessions/current"
    expect(body).to eq("active" => false)
    expect(SignatureSession.where(user_id: doctor.id, status: "active")).to be_empty
  end

  it "o PSC do certificado deixou de estar habilitado na cidade: 422 invalid_provider" do
    linked_certificate!(doctor, provider: "birdid", leaf: fake_psc.leaf(cpf))
    sign_in_as(doctor)
    post "/signature/sessions", params: { return_to: "/fila" }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_provider" ])
  end

  context "com o interruptor signature_psc_mock ligado" do
    before { stub_psc_mock! }

    it "certificado vidaas (PSC real) não abre sessão: 422 invalid_provider" do
      linked_certificate!(doctor, provider: "vidaas", leaf: fake_psc("simulated").leaf(cpf))
      sign_in_as(doctor)
      post "/signature/sessions", params: { return_to: "/fila" }, as: :json
      expect([ response.status, body["error"] ]).to eq([ 422, "invalid_provider" ])
    end

    it "certificado simulated abre a sessão e o payload mostra o provider como gravado" do
      linked_certificate!(doctor, provider: "simulated", leaf: fake_psc("simulated").leaf(cpf))
      sign_in_as(doctor)
      open_session!(key: "simulated")
      expect(response).to have_http_status(:ok)
      get "/signature/sessions/current"
      expect(body).to include("active" => true, "provider" => "simulated")
    end
  end
end
