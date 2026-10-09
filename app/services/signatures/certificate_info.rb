# app/services/signatures/certificate_info.rb
# Leitura do certificado ICP-Brasil de pessoa física (DOC-ICP-04; ADR 0032):
# CPF e nascimento no otherName 2.16.76.1.3.1 do subjectAltName (OCTET STRING
# ou texto, conforme a AC), nome no CN ("NOME:CPF"). Nenhuma mensagem de erro e
# nenhum inspect carregam CPF, nome ou bytes do certificado.
require "openssl"

module Signatures
  class CertificateInfo
    ICP_PF_OID = "2.16.76.1.3.1".freeze
    SIGNING_USAGE = [ "Digital Signature", "Non Repudiation" ].freeze

    class Invalid < StandardError; end

    attr_reader :certificate

    def self.parse(der)
      new(OpenSSL::X509::Certificate.new(der))
    rescue OpenSSL::X509::CertificateError, TypeError
      raise Invalid, "certificado ilegível"
    end

    def initialize(certificate)
      @certificate = certificate
    end

    def der = certificate.to_der
    def serial_number = certificate.serial.to_s(16).upcase
    def issuer_dn = certificate.issuer.to_s(OpenSSL::X509::Name::RFC2253)
    def issuer_name = entry(certificate.issuer, "CN") || issuer_dn
    def not_before = certificate.not_before
    def not_after = certificate.not_after
    def expired?(now = Time.current) = now >= not_after || now < not_before
    def holder_name = entry(certificate.subject, "CN").to_s.split(":").first.to_s.strip

    def cpf
      san = certificate.extensions.find { |extension| extension.oid == "subjectAltName" }
      return nil unless san

      names = OpenSSL::ASN1.decode(OpenSSL::ASN1.decode(san.to_der).value.last.value)
      names.value.each do |general_name|
        next unless general_name.tag_class == :CONTEXT_SPECIFIC && general_name.tag.zero?

        type_id, wrapped = general_name.value
        next unless type_id.respond_to?(:oid) && type_id.oid == ICP_PF_OID

        digits = Array(wrapped.value).first&.value.to_s[8, 11]
        return digits if digits&.match?(/\A\d{11}\z/)
      end
      nil
    rescue OpenSSL::ASN1::ASN1Error, NoMethodError, TypeError
      nil
    end

    # NGS2.02.02: digitalSignature + nonRepudiation.
    def signing_usage?
      usage = certificate.extensions.find { |extension| extension.oid == "keyUsage" }&.value.to_s.split(", ")
      (SIGNING_USAGE - Array(usage)).empty?
    end

    def inspect = "#<Signatures::CertificateInfo serial=#{serial_number}>"

    private

    # OpenSSL entrega os valores como ASCII-8BIT; os nomes do certificado são UTF-8.
    def entry(name, key) = name.to_a.find { |(k, _value, _type)| k == key }&.at(1)&.dup&.force_encoding(Encoding::UTF_8)&.scrub
  end
end
