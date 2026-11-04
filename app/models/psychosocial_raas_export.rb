# Remessa RAAS do mês de um CAPS (ADR 0049): uma por CAPS e mês, com a
# competência de apresentação (calendário do 22), a versão do layout, o arquivo
# (Base64, cifrado com a chave da cidade) e o SHA-256. Só acréscimo (trigger).
# O arquivo traz dado do paciente: nunca sai em inspect, to_s, pretty_print nem
# as_json — só o id.
class PsychosocialRaasExport < ApplicationRecord
  encrypts :file_data

  belongs_to :health_unit
  belongs_to :billing_period
  belongs_to :created_by_user, class_name: "User"
  has_many :psychosocial_monthly_records, inverse_of: :psychosocial_raas_export, dependent: :restrict_with_error

  def inspect = "#<PsychosocialRaasExport id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
