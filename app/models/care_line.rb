# app/models/care_line.rb
# Linha de cuidado da cidade (ADR 0040; spec §4): adotada do catálogo-base
# (cópia das regras da versão adotada) ou própria, com as mesmas formas.
class CareLine < ApplicationRecord
  belongs_to :updated_by_user, class_name: "User"
  has_many :enrollments, class_name: "CareLineEnrollment", dependent: :restrict_with_error

  scope :active_lines, -> { where(active: true) }

  def template? = source == "template"
  def requires_lmp? = eligibility["requires_anchor"] == "lmp"
end
