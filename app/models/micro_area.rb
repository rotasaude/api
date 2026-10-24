# Microárea da equipe (módulo 24a, ADR 0042): código de 2 dígitos único na
# equipe, nome e o ACS responsável (opcional). Código e equipe nunca mudam e
# nada se apaga (trigger); desativar grava active = false.
class MicroArea < ApplicationRecord
  CODE = /\A(0[1-9]|[1-9][0-9])\z/

  belongs_to :team, class_name: "HealthTeam"
  belongs_to :acs_professional, class_name: "Professional", optional: true
  has_many :households, dependent: :restrict_with_error

  normalizes :name, with: ->(v) { v.to_s.squish }

  validates :code, format: { with: CODE }
  validates :name, presence: true, length: { maximum: 60 }

  def inspect = "#<MicroArea id=#{id} team_id=#{team_id} acs_professional_id=#{acs_professional_id}>"
end
