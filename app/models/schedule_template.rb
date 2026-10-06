# Modelo de agenda (ADR 0029 §3.2): faixas walk_in/bookable/blocked em hora
# local e o limite de encaixes do turno. Validado por Scheduling::TemplateBlocks.
class ScheduleTemplate < ApplicationRecord
  has_many :shifts, class_name: "ProfessionalShift", dependent: :restrict_with_error
end
