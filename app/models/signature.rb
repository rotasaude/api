# app/models/signature.rb
# Assinatura gravada (ADR 0032; spec §4, §7): o JSON canônico assinado (CAdES
# destacado, fonte de verdade), o PDF assinado (PAdES) e as provas de validade
# do ato. Só acréscimo: muda só a validação (trigger signatures_guard).
class Signature < ApplicationRecord
  POLICIES = %w[AD-RB AD-RT].freeze
  VERIFICATIONS = %w[valid invalid indeterminate].freeze

  encrypts :canonical_json, :cades, :signed_pdf, :validation_material
  encrypts :signer_cpf, deterministic: true, key_provider: CityDeterministicKeyProvider.new

  belongs_to :signature_request
  belongs_to :signer_certificate

  validates :provider, inclusion: { in: SignerCertificate::PROVIDERS }

  def simulated? = provider == "simulated"
  def cades_bytes = Base64.strict_decode64(cades)
  def signed_pdf_bytes = Base64.strict_decode64(signed_pdf)
  def material = JSON.parse(validation_material)
  def inspect = "#<Signature id=#{id} document_type=#{document_type} last_verification=#{last_verification}>"
end
