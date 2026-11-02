# Sala de vacina (ADR 0047): uma por unidade, com local de estoque próprio do
# tipo vaccine_room (Desvio 4). Nunca é apagada (trigger): desativa-se.
class VaccineRoom < ApplicationRecord
  belongs_to :health_unit
  belongs_to :stock_location
  belongs_to :updated_by_user, class_name: "User"
  has_many :staff, class_name: "VaccineRoomStaff", inverse_of: :vaccine_room
  has_many :immunizations, inverse_of: :vaccine_room
  has_many :vial_openings, inverse_of: :vaccine_room

  scope :active_rooms, -> { where(active: true) }
end
