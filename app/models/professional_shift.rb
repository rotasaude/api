# Turno com instantes de início e fim (ADR 0021, emenda de 2026-09-27). Só
# acréscimo: cancelar grava hora, quem e motivo. Nunca bloqueia ato clínico.
class ProfessionalShift < ApplicationRecord
  belongs_to :professional_link
  belongs_to :professional
  belongs_to :created_by_user, class_name: "User"
  belongs_to :cancelled_by_user, class_name: "User", optional: true

  scope :valid_shifts, -> { where(cancelled_at: nil) }
end
