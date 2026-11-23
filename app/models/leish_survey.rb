# Inquérito de leishmaniose visceral canina (módulo 35b, ADR 0054; contrato §1
# e §6): draft → open → closed, sem voltar (trigger). Sem dado pessoal.
class LeishSurvey < ApplicationRecord
  belongs_to :neighborhood
  has_many :tests, class_name: "LeishTest", inverse_of: :leish_survey, dependent: :restrict_with_error

  def inspect = "#<LeishSurvey id=#{id} stage=#{stage}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "stage" => stage }
end
