# Município. Stub mínimo — ADR próprio quando o domínio amadurecer.
# settings (jsonb) carrega: alert_channel ("email"|"webhook"), alert_email, alert_webhook.
class Municipality < ApplicationRecord
  has_many :conversations,         dependent: :restrict_with_error
  has_many :dashboard_metrics,     dependent: :delete_all
  has_many :protocol_definitions,  dependent: :restrict_with_error

  validates :name, :slug, presence: true
  validates :slug, uniqueness: true
  validates :ibge_code, uniqueness: true, allow_nil: true
end
