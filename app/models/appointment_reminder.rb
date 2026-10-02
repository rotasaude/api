# Lembrete de confirmação do horário (api#39; ADR 0019, Revisão 2026-10-02).
# Um por horário, só acréscimo: registra que o lembrete foi tentado e o
# resultado. Sem telefone nem texto — o texto é fixo e o telefone é do cidadão.
class AppointmentReminder < ApplicationRecord
  STATUSES = %w[sent failed unavailable disabled opted_out].freeze

  belongs_to :appointment

  validates :status, inclusion: { in: STATUSES }
end
