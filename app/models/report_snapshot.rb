# Relatório congelado de uma triage. Imutável após criação. Ver ADR-0010.
class ReportSnapshot < ApplicationRecord
  belongs_to :triage
  belongs_to :protocol_definition

  validates :token, :signature, :payload, :outcome, presence: true
  validates :token, uniqueness: true

  scope :live, -> { where("expires_at > ?", Time.current) }

  def self.find_by_signed_token(token)
    record = find_by(token: token)
    return nil unless record
    return nil unless ActiveSupport::SecurityUtils.secure_compare(record.signature, sign(token))
    return nil if record.expires_at && record.expires_at < Time.current
    record
  end

  def self.sign(token)
    key = Rails.application.credentials.fetch(:report_signing_key)
    OpenSSL::HMAC.hexdigest("sha256", key, token)
  end

  def self.mint_token
    SecureRandom.urlsafe_base64(32)
  end

  # Link do cidadão: host da cidade do snapshot (Plano 6). O único chamador é
  # NotifyCitizenJob, que roda dentro de CityScopedJob#with_city — Current.city
  # está setado. Sem cidade, CityPublicUrl levanta em vez de mandar um link
  # para o host errado.
  def url
    "#{CityPublicUrl.wpda(Current.city)}?token=#{token}"
  end
end
