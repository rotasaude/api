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
    return nil unless signature_matches?(record, token)
    return nil if record.expires_at && record.expires_at < Time.current
    record
  end

  def self.sign(token)
    OpenSSL::HMAC.hexdigest("sha256", CityEncryption.report_signing_key(Current.city), token)
  end

  # Transição do Plano 8: assinaturas gravadas antes da chave por cidade usam a
  # chave global. A rake city:resign_reports[slug] reescreve as existentes; este
  # fallback pode sair depois de 30 dias (GenerateReportJob::EXPIRATION), quando
  # todo snapshot vivo já tiver nascido com a chave da cidade.
  def self.signature_matches?(record, token)
    return true if ActiveSupport::SecurityUtils.secure_compare(record.signature, sign(token))

    legacy = OpenSSL::HMAC.hexdigest("sha256", CityEncryption.legacy_report_signing_key, token)
    ActiveSupport::SecurityUtils.secure_compare(record.signature, legacy)
  end
  private_class_method :signature_matches?

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
