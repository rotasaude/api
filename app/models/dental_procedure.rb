# Procedimento odontológico da consulta (ADR 0046): SIGTAP, local (dente,
# face, sextante, arcada ou boca; coerência por CHECK) e quantidade. Item da
# consulta: no rascunho e nunca muda (trigger). Dado clínico fora de inspect,
# to_s, pretty_print e as_json.
class DentalProcedure < ApplicationRecord
  belongs_to :consultation
  belongs_to :patient
  belongs_to :dental_treatment_plan_item, optional: true
  belongs_to :dental_prosthesis_order, optional: true

  def inspect = "#<DentalProcedure id=#{id} consultation_id=#{consultation_id} patient_id=#{patient_id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
