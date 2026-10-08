# Dois pares validados do mesmo CPF com nascimento ou sexo diferentes (ADR
# 0031; spec §3). Só acréscimo; o paciente segue o par validado mais recente.
class PatientProfileDivergence < ApplicationRecord
  FIELDS = %w[birth_date sex].freeze

  belongs_to :patient
  belongs_to :citizen
end
