# Perfil do CEO (ADR 0046): tipo (I, II, III) e especialidades da unidade
# `ceo`, mantido pelo admin municipal. Um por unidade; nunca é apagado
# (trigger).
class CeoProfile < ApplicationRecord
  belongs_to :health_unit, inverse_of: :ceo_profile
  belongs_to :updated_by_user, class_name: "User"

  validates :ceo_type, inclusion: { in: DentalCare::Catalog::CEO_TYPES }
  validates :specialties, presence: true
  validate { errors.add(:specialties, :inclusion) unless (Array(specialties) - DentalCare::Catalog::CEO_SPECIALTIES).empty? }
end
