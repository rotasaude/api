# lib/fake_psc/pki.rb
# AC de TESTE no formato ICP-Brasil (DOC-ICP-04), com os arquivos do DevPki do
# signer (root.pem, intermediate.pem, intermediate.key.pem). Em dev, lê o volume
# do signer (SIGNER_DEV_PKI_DIR): o signer confia nela e serve as LCRs. Sem o
# volume, a cópia commitada em spec/fixtures/signature_pki. NUNCA é carregada
# em produção: só por require explícito (specs, lib/fake_psc/config.ru).
require "openssl"
require "fileutils"

module FakePsc
  class Pki
    FIXTURES = File.expand_path("../../spec/fixtures/signature_pki", __dir__)
    ICP_PF_OID = "2.16.76.1.3.1".freeze
    DEFAULT_CRL_BASE = "http://signer:8090/dev-pki/".freeze

    Leaf = Data.define(:certificate, :key) do
      def der = certificate.to_der
      def serial_hex = certificate.serial.to_s(16).upcase
      def inspect = "#<FakePsc::Pki::Leaf #{serial_hex}>"
    end

    attr_reader :root, :ca

    def self.load(dir = ENV["SIGNER_DEV_PKI_DIR"].to_s.empty? ? FIXTURES : ENV["SIGNER_DEV_PKI_DIR"],
                  crl_base: ENV.fetch("SIGNER_DEV_PKI_CRL_BASE", DEFAULT_CRL_BASE))
      read = ->(name) { File.read(File.join(dir, name)) }
      new(root: OpenSSL::X509::Certificate.new(read.call("root.pem")),
          ca: OpenSSL::X509::Certificate.new(read.call("intermediate.pem")),
          ca_key: OpenSSL::PKey.read(read.call("intermediate.key.pem")), crl_base: crl_base)
    end

    # Uma vez só, para a cópia de spec/fixtures (em dev quem gera é o signer).
    def self.generate!(dir = FIXTURES, crl_base: DEFAULT_CRL_BASE)
      FileUtils.mkdir_p(dir)
      root_key = OpenSSL::PKey::RSA.new(2048)
      root = authority("/C=BR/O=ICP-Brasil/CN=AC Raiz de Teste Rota Saude", root_key, nil, root_key, 20, nil, nil)
      ca_key = OpenSSL::PKey::RSA.new(2048)
      ca = authority("/C=BR/O=ICP-Brasil/OU=Teste/CN=AC Rota Saude Teste v1", ca_key, root, root_key, 10, 0,
                     "#{crl_base}root.crl")
      { "root.pem" => root.to_pem, "intermediate.pem" => ca.to_pem, "intermediate.key.pem" => ca_key.private_to_pem,
        "anchors.pem" => root.to_pem + ca.to_pem }.each { |name, pem| File.write(File.join(dir, name), pem) }
      dir
    end

    def self.authority(subject, key, issuer, issuer_key, years, path_len, crl_url)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = OpenSSL::BN.rand(64)
      cert.subject = OpenSSL::X509::Name.parse(subject)
      cert.issuer = issuer ? issuer.subject : cert.subject
      cert.public_key = key.public_key
      cert.not_before = Time.now - 3600
      cert.not_after = Time.now + (years * 365 * 86_400)
      ef = OpenSSL::X509::ExtensionFactory.new(issuer || cert, cert)
      cert.add_extension(ef.create_extension("basicConstraints", path_len ? "CA:TRUE,pathlen:#{path_len}" : "CA:TRUE", true))
      cert.add_extension(ef.create_extension("keyUsage", "keyCertSign,cRLSign", true))
      cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash"))
      cert.add_extension(ef.create_extension("authorityKeyIdentifier", "keyid:always")) if issuer
      cert.add_extension(ef.create_extension("crlDistributionPoints", "URI:#{crl_url}")) if crl_url
      cert.sign(issuer_key, OpenSSL::Digest.new("SHA256"))
      cert
    end
    private_class_method :authority

    def initialize(root:, ca:, ca_key:, crl_base: DEFAULT_CRL_BASE)
      @root = root
      @ca = ca
      @ca_key = ca_key
      @crl_base = crl_base.end_with?("/") ? crl_base : "#{crl_base}/"
      @leaves = {}
      @mutex = Mutex.new
    end

    # e-CPF de teste no formato do DevPki do signer.
    def issue(cpf:, name:, birth_date: "01011980", not_before: Time.now - 60, not_after: Time.now + (365 * 86_400),
              key_usage: "digitalSignature,nonRepudiation")
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = OpenSSL::BN.rand(64)
      cert.subject = OpenSSL::X509::Name.new([ [ "C", "BR" ], [ "O", "ICP-Brasil" ], [ "OU", "Teste" ],
                                               [ "CN", "#{name}:#{cpf}", OpenSSL::ASN1::UTF8STRING ] ])
      cert.issuer = @ca.subject
      cert.public_key = key.public_key
      cert.not_before = not_before
      cert.not_after = not_after
      ef = OpenSSL::X509::ExtensionFactory.new(@ca, cert)
      cert.add_extension(ef.create_extension("basicConstraints", "CA:FALSE", true))
      cert.add_extension(ef.create_extension("keyUsage", key_usage, true))
      cert.add_extension(ef.create_extension("authorityKeyIdentifier", "keyid:always"))
      cert.add_extension(ef.create_extension("crlDistributionPoints", "URI:#{@crl_base}intermediate.crl"))
      cert.add_extension(icp_san(cpf, birth_date))
      cert.sign(@ca_key, OpenSSL::Digest.new("SHA256"))
      Leaf.new(certificate: cert, key: key)
    end

    def leaf_for(cpf, name: "PROFISSIONAL DE TESTE #{cpf.to_s[-4..]}")
      @mutex.synchronize { @leaves[cpf] ||= issue(cpf: cpf, name: name) }
    end

    def replace_leaf!(cpf, leaf) = @mutex.synchronize { @leaves[cpf] = leaf }

    def inspect = "#<FakePsc::Pki>"

    private

    # [0] otherName { 2.16.76.1.3.1, [0] EXPLICIT OCTET STRING } — nascimento
    # (ddMMaaaa) + CPF + NIS (11 zeros) + RG (15 zeros) + órgão/UF (6 zeros).
    def icp_san(cpf, birth_date)
      value = "#{birth_date}#{cpf}#{'0' * 11}#{'0' * 15}#{'0' * 6}"
      other_name = OpenSSL::ASN1::ASN1Data.new(
        [ OpenSSL::ASN1::ObjectId.new(ICP_PF_OID),
          OpenSSL::ASN1::ASN1Data.new([ OpenSSL::ASN1::OctetString.new(value) ], 0, :CONTEXT_SPECIFIC) ],
        0, :CONTEXT_SPECIFIC
      )
      OpenSSL::X509::Extension.new("subjectAltName", OpenSSL::ASN1::Sequence.new([ other_name ]).to_der)
    end
  end
end
