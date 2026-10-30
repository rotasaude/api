# Periograma da consulta, por dente (ADR 0046): mobilidade e furca, com os
# sítios medidos. Item da consulta: no rascunho e nunca muda (trigger). Dado
# clínico fora de inspect, to_s, pretty_print e as_json.
class PeriodontalChart < ApplicationRecord
  belongs_to :consultation
  belongs_to :patient
  has_many :sites, class_name: "PeriodontalSite", inverse_of: :periodontal_chart, dependent: :restrict_with_error

  def inspect = "#<PeriodontalChart id=#{id} consultation_id=#{consultation_id} patient_id=#{patient_id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
