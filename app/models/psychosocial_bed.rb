# Leito do acolhimento noturno de um CAPS (ADR 0049): rótulo único no CAPS;
# desativado sai do mapa. Nunca é apagado (trigger).
class PsychosocialBed < ApplicationRecord
  belongs_to :health_unit
  belongs_to :updated_by_user, class_name: "User"
  has_many :psychosocial_night_stays, inverse_of: :psychosocial_bed, dependent: :restrict_with_error
end
