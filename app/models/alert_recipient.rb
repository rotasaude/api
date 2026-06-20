# Destinatário de alerta urgente por município (ADR-0024).
# Esta tabela é APENAS configuração. SLA, escalonamento real, monitoramento
# são fora de escopo (ver §1.2 do brief).
class AlertRecipient < ApplicationRecord
  belongs_to :municipality
  CHANNELS = %w[whatsapp email].freeze
  validates :channel, inclusion: { in: CHANNELS }
  validates :destination, presence: true
  scope :active, -> { where(active: true).order(:escalation_order) }
end
