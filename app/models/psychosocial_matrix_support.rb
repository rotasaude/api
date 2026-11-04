# Matriciamento do CAPS com uma equipe da atenção básica (ADR 0049): encontro
# com tema (cifrado com a chave da cidade), participantes e a ação SIGTAP que
# ele gera (uma por encontro). Só acréscimo (trigger).
class PsychosocialMatrixSupport < ApplicationRecord
  encrypts :topic

  belongs_to :health_unit
  belongs_to :health_team
  belongs_to :psychosocial_action
  belongs_to :recorded_by_user, class_name: "User"
  has_many :psychosocial_matrix_cases, inverse_of: :psychosocial_matrix_support, dependent: :restrict_with_error

  def inspect = "#<PsychosocialMatrixSupport id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
