# app/models/signer_certificate.rb
# Certificado ICP-Brasil em nuvem vinculado ao profissional (ADR 0032; spec
# §4). Um `active` por usuário (índice parcial). CPF e certificado cifrados com
# a chave da cidade; o CPF é determinístico para conferir sem decifrar tudo.
class SignerCertificate < ApplicationRecord
  # Os PSCs reais; `simulated` é o PSC simulado de desenvolvimento
  # (signature_psc_mock, nunca em produção), aceito só no que fica gravado.
  REAL_PROVIDERS = %w[vidaas birdid safeid neoid remoteid].freeze
  PROVIDERS = (REAL_PROVIDERS + %w[simulated]).freeze
  STATUSES = %w[active replaced unlinked revoked expired].freeze
  EXPIRING_WITHIN = 30.days

  encrypts :subject_cpf, deterministic: true, key_provider: CityDeterministicKeyProvider.new
  encrypts :certificate_der

  belongs_to :user

  scope :active, -> { where(status: "active") }

  validates :provider, inclusion: { in: PROVIDERS }
  validates :status, inclusion: { in: STATUSES }

  def der = Base64.strict_decode64(certificate_der)
  def info = (@info ||= Signatures::CertificateInfo.parse(der))
  def expires_in_days(now = Time.current) = ((not_after - now) / 1.day).floor
  def expiring?(now = Time.current) = not_after <= now + EXPIRING_WITHIN
  def inspect = "#<SignerCertificate id=#{id} provider=#{provider} status=#{status}>"
end
