# Família do domicílio (módulo 24a, ADR 0042): o responsável é um paciente;
# renda e "reside desde" ("AAAA-MM") cifrados com a chave da cidade. Mudança
# grava moved_out; domicílio e responsável nunca mudam e nada se apaga
# (trigger). Um responsável ativo por domicílio (índice único parcial).
class Family < ApplicationRecord
  encrypts :income_band, :living_since

  belongs_to :household
  belongs_to :responsible_patient, class_name: "Patient"

  scope :active_families, -> { where(moved_out: false) }

  validates :members_count, numericality: { only_integer: true, in: 1..999 }, allow_nil: true

  def inspect = "#<Family id=#{id} household_id=#{household_id} responsible_patient_id=#{responsible_patient_id}>"
end
