# Registro periodontal simplificado da consulta (ADR 0046): código 0..4 por
# sextante (nulo = sextante excluído, "X"), com asterisco. Item da consulta:
# no rascunho e nunca muda (trigger). Dado clínico fora de inspect, to_s,
# pretty_print e as_json.
class PeriodontalScreening < ApplicationRecord
  belongs_to :consultation
  belongs_to :patient

  def inspect = "#<PeriodontalScreening id=#{id} consultation_id=#{consultation_id} patient_id=#{patient_id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
