# Relatório congelado de uma triage. Imutável após criação. Ver ADR-0007.
class ReportSnapshot < ApplicationRecord
  belongs_to :triage
  belongs_to :protocol_definition

  validates :token, :signature, :payload, presence: true
  validates :outcome, exclusion: { in: [nil] }
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

  def url
    base = ENV.fetch("WPDA_PUBLIC_BASE", "http://localhost:5176/wpda")
    "#{base.chomp('/')}/?token=#{token}"
  end
end
