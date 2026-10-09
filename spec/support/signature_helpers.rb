# spec/support/signature_helpers.rb
# Assinatura digital (ADR 0032). Os helpers que falam com o PSC falso e com o
# signer falso entram nas Tasks 4 e 5, neste mesmo módulo.
require_relative "../../lib/fake_psc/pki"

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

  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)
end

RSpec.configure { |c| c.include SignatureHelpers }
