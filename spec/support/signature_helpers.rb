# spec/support/signature_helpers.rb
# Assinatura digital (ADR 0032): helpers do PSC falso e do signer falso.
require_relative "../../lib/fake_psc/pki"
require_relative "../../lib/fake_psc/app"
require "webmock/rspec"

module SignatureHelpers
  DOCTOR_CPF = "52998224725".freeze
  OTHER_CPF = "11144477735".freeze

  # Uma AC de teste por processo (as folhas são memorizadas por CPF).
  def test_pki = ($signature_test_pki ||= FakePsc::Pki.load)

  # TEST_CITY_A com o prontuário e a assinatura ligados (ou não).
  def signature_city!(enabled: true)
    city = clinical_city!
    Platform::Features.set!(city: city, key: "digital_signature", enabled: enabled, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    city
  end

  # Com MFA cadastrado (como nas specs do 19a): vincular, desvincular e abrir
  # sessão pedem step-up, e o step-up exige o autenticador.
  def signer_doctor!(unit, cpf: DOCTOR_CPF)
    doctor!(unit).tap do |user|
      user.professional.update!(cpf: cpf)
      Mfa::Enroll.call(user)
      user.update!(otp_enabled: true)
    end
  end

  def linked_certificate!(user, provider: "vidaas", status: "active", leaf: nil)
    leaf ||= test_pki.leaf_for(user.professional.cpf)
    info = Signatures::CertificateInfo.new(leaf.certificate)
    SignerCertificate.create!(user: user, provider: provider, certificate_alias: info.cpf, serial_number: info.serial_number,
                              issuer_dn: info.issuer_dn, subject_cpf: info.cpf, not_before: info.not_before,
                              not_after: info.not_after, status: status, certificate_der: Base64.strict_encode64(leaf.der))
  end

  def signature_session!(user, certificate:, token: "token-de-teste", expires_at: 8.hours.from_now, started_at: Time.current)
    SignatureSession.create!(user: user, signer_certificate: certificate, provider: certificate.provider, access_token: token,
                             scope: SignatureSession::SCOPE, started_at: started_at, expires_at: expires_at)
  end

  # Sem documento: um id qualquer (a tabela não tem FK para o documento).
  def signature_request!(document = nil, author:, status: "pending", reason_code: nil)
    type = document ? Signatures::DocumentTypes.db(document) : "Consultation"
    SignatureRequest.create!(document_type: type, document_id: document&.id || SecureRandom.uuid,
                             consultation_id: document ? Signatures::DocumentTypes.consultation_id(document) : SecureRandom.uuid,
                             author_user_id: author.id, status: status, reason_code: reason_code,
                             resolved_at: %w[signed returned_to_paper].include?(status) ? Time.current : nil)
  end

  def signature_row!(request, certificate:, canonical_json: "{\"a\":1}")
    Signature.create!(signature_request: request, document_type: request.document_type, document_id: request.document_id,
                      canonical_json: canonical_json, canonical_sha256: Digest::SHA256.hexdigest(canonical_json),
                      cades: Base64.strict_encode64("cades"), signed_pdf: Base64.strict_encode64("%PDF-1.7 assinado"),
                      pdf_sha256: Digest::SHA256.hexdigest("%PDF-1.7 assinado"), policy: "AD-RB",
                      provider: certificate.provider,
                      policy_oid: "2.16.76.1.7.1.1.2.3", validation_material: { "cades" => "", "pades" => "" }.to_json,
                      signer_certificate: certificate, signer_cpf: certificate.subject_cpf, signed_at: Time.current,
                      last_verification: "valid", last_verification_at: Time.current)
  end

  def stub_signer!(fake = FakeSigner.new)
    allow(Signatures::Signer).to receive(:client).and_return(fake)
    fake
  end

  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)

  PSC_BASES = { "vidaas" => "https://psc-vidaas.test", "birdid" => "https://psc-birdid.test",
                "simulated" => "https://psc-simulated.test" }.freeze

  def fake_psc(key = "vidaas") = (@fake_pscs ||= {})[key] ||= FakePsc::App.new(pki: test_pki)

  # Credenciais da plataforma só destes PSC (reais), cada um servido pelo seu
  # falso. Vale com o interruptor signature_psc_mock DESLIGADO.
  def stub_psc!(keys = %w[vidaas])
    credentials = keys.to_h do |key|
      [ key, { "client_id" => FakePsc::App::CLIENT_ID, "client_secret" => FakePsc::App::CLIENT_SECRET,
               "base_url" => PSC_BASES.fetch(key) } ]
    end
    allow(Signatures::Providers).to receive(:credentials).and_return(credentials)
    keys.each { |key| stub_request(:any, /\A#{Regexp.escape(PSC_BASES.fetch(key))}/).to_rack(fake_psc(key)) }
  end

  # O PSC simulado (ADR 0032, revisão): liga digital_signature e
  # signature_psc_mock na cidade (signature_city! por padrão; vira a
  # Current.city), aponta FAKE_PSC_URL/FAKE_PSC_PUBLIC_URL para o falso e o
  # serve por WebMock. Devolve a cidade.
  def stub_psc_mock!(city = nil)
    city ||= signature_city!
    [ Signatures::Gate::KEY, Signatures::PscMock::KEY ].each do |key|
      Platform::Features.set!(city: city, key: key, enabled: true, maintainer: ledi_maintainer!)
    end
    base = PSC_BASES.fetch("simulated")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FAKE_PSC_URL").and_return(base)
    allow(ENV).to receive(:[]).with("FAKE_PSC_PUBLIC_URL").and_return(nil)
    stub_request(:any, /\A#{Regexp.escape(base)}/).to_rack(fake_psc("simulated"))
    city
  end

  # O navegador abre a URL de autorização (o falso registra o pedido) e o
  # titular aprova no "celular". Devolve o code.
  def authorize_and_approve!(url, key: "vidaas")
    Net::HTTP.get_response(URI(url))
    state = URI.decode_www_form(URI(url).query).to_h.fetch("state")
    fake_psc(key).approve!(state)
  end
end

RSpec.configure do |config|
  config.include SignatureHelpers

  # Specs :signer falam com o serviço real (compose: http://signer:8090). Sem
  # SIGNER_URL ficam fora — com aviso, nunca em silêncio.
  if ENV["SIGNER_URL"].to_s.empty?
    config.filter_run_excluding(:signer)
    config.before(:suite) { warn "[signer] SIGNER_URL ausente: specs :signer fora desta corrida" }
  end

  config.around(:each, :signer) do |example|
    WebMock.disable_net_connect!(allow: URI(ENV.fetch("SIGNER_URL")).host)
    example.run
  ensure
    WebMock.disable_net_connect!
  end
end
