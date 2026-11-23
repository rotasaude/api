# Coleta e resultado da sorologia canina (módulo 35b, ADR 0054; contrato §1 e
# §6): etiqueta única, TR-DPP e ELISA (este só depois de um DPP reagente,
# CHECK). O animal e o número da requisição nunca saem em inspect, to_s,
# pretty_print nem as_json — só o id.
class LeishTest < ApplicationRecord
  belongs_to :leish_survey, optional: true, inverse_of: :tests
  belongs_to :animal
  belongs_to :result_by_user, class_name: "User", optional: true
  has_one :outcome, class_name: "LeishDogOutcome", inverse_of: :leish_test, dependent: :restrict_with_error

  def inspect = "#<LeishTest id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
