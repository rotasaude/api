# Evento do odontograma (ADR 0046): situação (ou procedimento) num dente, na
# coroa (com ou sem face) ou na raiz. O odontograma nunca é coluna: é a dobra
# dos eventos do paciente em ordem (DentalCare::Chart). Nasce no rascunho ou
# com adendo desta consulta e nunca muda nem some (trigger). Dado clínico fora
# de inspect, to_s, pretty_print e as_json.
class DentalChartEvent < ApplicationRecord
  # `seq` (identidade GENERATED ALWAYS, ordem de gravação) é do banco: fora dos
  # atributos para o INSERT não mandar NULL; ordene por `order(:recorded_at, :seq)`.
  self.ignored_columns += %w[seq]

  belongs_to :patient
  belongs_to :consultation
  belongs_to :addendum, class_name: "ConsultationAddendum", optional: true
  belongs_to :dental_procedure, optional: true
  belongs_to :author_user, class_name: "User"

  def inspect = "#<DentalChartEvent id=#{id} consultation_id=#{consultation_id} patient_id=#{patient_id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
