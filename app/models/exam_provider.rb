# Prestador de exames da cidade (ADR 0036): laboratório, consórcio, LACEN,
# clínica de imagem. Token FHIR guardado só como SHA-256; revogável.
# `simulated` só a semente de dev grava (o laboratório simulado).
class ExamProvider < ApplicationRecord
  KINDS = %w[municipal accredited consortium lacen imaging].freeze

  has_many :items, class_name: "ExamProviderItem", dependent: :restrict_with_error
  has_many :provider_users, class_name: "ExamProviderUser", dependent: :restrict_with_error

  validates :name, presence: true, length: { maximum: 120 }
  validates :kind, inclusion: { in: KINDS }
  validates :cnes, format: { with: /\A\d{7}\z/ }, allow_nil: true

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)

  def self.by_token(token)
    return nil unless token.is_a?(String) && token.length.between?(32, 128)

    find_by(fhir_token_digest: digest(token), fhir_token_revoked_at: nil, active: true)
  end

  def fhir_token_active? = fhir_token_digest.present? && fhir_token_revoked_at.nil?
  def inspect = "#<ExamProvider id=#{id} kind=#{kind} active=#{active}>"
end
