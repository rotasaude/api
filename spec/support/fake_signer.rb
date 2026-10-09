# Signer falso, em processo, com a interface de Signatures::Signer::Client
# (contrato §9). Confere de verdade a assinatura RAW contra a chave pública do
# certificado e recusa documento adulterado; o formato das "assinaturas" é
# dele. A prova de CAdES/PAdES ICP é das specs :signer, contra o serviço.
class FakeSigner
  POLICY_OID = "2.16.76.1.7.1.1.2.3".freeze
  MARKER = "\n%FAKE-PADES ".b.freeze

  attr_accessor :unavailable, :revoked_serials, :untrusted_serials, :revocation_unavailable
  attr_reader :calls

  def initialize
    @unavailable = false
    @revoked_serials = []
    @untrusted_serials = []
    @revocation_unavailable = false
    @calls = []
  end

  # Como o serviço real: certificado revogado ou de cadeia não confiável é
  # 422 invalid_certificate no /prepare (R9); LCR fora do ar seria 500 =
  # indisponibilidade transitória (revocation_unavailable).
  def prepare(kind:, document:, certificate_der:)
    touch!(:prepare)
    info = Signatures::CertificateInfo.parse(certificate_der)
    raise Signatures::Signer::Rejected, "invalid_certificate" if @revoked_serials.include?(info.serial_number) ||
                                                                 @untrusted_serials.include?(info.serial_number)
    raise Signatures::Signer::Unavailable, "o signer respondeu 500" if @revocation_unavailable

    doc = Digest::SHA256.hexdigest(document)
    state = { "kind" => kind, "doc" => doc, "cert" => Base64.strict_encode64(certificate_der),
              "pdf" => kind == "pades" ? Base64.strict_encode64(document) : nil }
    Signatures::Signer::Prepared.new(digest: Digest::SHA256.digest("#{kind}|#{doc}"),
                                     state: Base64.strict_encode64(JSON.generate(state)))
  rescue Signatures::CertificateInfo::Invalid
    raise Signatures::Signer::Rejected, "invalid_certificate"
  end

  def assemble(kind:, state:, signature_value:)
    touch!(:assemble)
    data = JSON.parse(Base64.strict_decode64(state))
    raise Signatures::Signer::Rejected, "invalid_request" unless data["kind"] == kind

    certificate = OpenSSL::X509::Certificate.new(Base64.strict_decode64(data["cert"]))
    digest = Digest::SHA256.digest("#{kind}|#{data['doc']}")
    unless certificate.public_key.verify_raw("SHA256", signature_value, digest)
      raise Signatures::Signer::Rejected, "invalid_signature_value"
    end

    envelope = JSON.generate("fake" => kind, "doc" => data["doc"], "cert" => data["cert"],
                             "sig" => Base64.strict_encode64(signature_value))
    signature = kind == "pades" ? Base64.strict_decode64(data["pdf"]).b + MARKER + Base64.strict_encode64(envelope).b : envelope.b
    Signatures::Signer::Assembled.new(signature: signature, validation_material: "fake-chain-#{kind}".b)
  rescue JSON::ParserError, ArgumentError
    raise Signatures::Signer::Rejected, "invalid_request"
  end

  def verify(kind:, signature:, document: nil)
    touch!(:verify)
    envelope, original = kind == "pades" ? split_pades(signature) : [ JSON.parse(signature), document ]
    info = Signatures::CertificateInfo.parse(Base64.strict_decode64(envelope["cert"]))
    reasons = []
    reasons << "document_altered" unless original && Digest::SHA256.hexdigest(original) == envelope["doc"]
    reasons << "certificate_revoked" if @revoked_serials.include?(info.serial_number)
    Signatures::Signer::Verification.new(status: reasons.empty? ? "valid" : "invalid", signer_cpf: info.cpf,
                                         signer_name: info.holder_name, policy_oid: POLICY_OID,
                                         signed_at: Time.current, reasons: reasons)
  rescue JSON::ParserError, ArgumentError, Signatures::CertificateInfo::Invalid
    Signatures::Signer::Verification.new(status: "invalid", signer_cpf: nil, signer_name: nil, policy_oid: nil,
                                         signed_at: nil, reasons: [ "malformed" ])
  end

  # Contrato D1: cadeia + LCR do certificado, sem assinar.
  def check_certificate(certificate_der:)
    touch!(:check)
    info = Signatures::CertificateInfo.parse(certificate_der)
    reasons = []
    reasons << "untrusted_chain" if @untrusted_serials.include?(info.serial_number)
    reasons << "certificate_expired" if info.expired?
    reasons << "certificate_revoked" if @revoked_serials.include?(info.serial_number)
    status = reasons.any? ? "invalid" : "valid"
    if status == "valid" && @revocation_unavailable
      status = "indeterminate"
      reasons << "revocation_unavailable"
    end
    Signatures::Signer::CertificateCheck.new(status: status, signer_cpf: info.cpf, not_after: info.not_after, reasons: reasons)
  rescue Signatures::CertificateInfo::Invalid
    raise Signatures::Signer::Rejected, "invalid_certificate"
  end

  def health
    touch!(:health)
    { version: "fake-1", crl_updated_at: Time.current }
  end

  def inspect = "#<FakeSigner calls=#{@calls.size}>"
  def pretty_print(pp) = pp.text(inspect)

  private

  def touch!(name)
    raise Signatures::Signer::Unavailable, "signer falso fora do ar" if @unavailable

    @calls << name
  end

  def split_pades(bytes)
    bytes = bytes.b
    at = bytes.rindex(MARKER)
    raise ArgumentError, "sem assinatura" unless at

    [ JSON.parse(Base64.strict_decode64(bytes[(at + MARKER.bytesize)..])), bytes[0...at] ]
  end
end
