# Um evento da lista de problemas (ADR 0031; spec §3): só acréscimo, com a
# consulta OU o adendo, o profissional e os valores novos. O txid amarra o
# evento à transação que muda o estado (trigger).
class PatientProblemEvent < ApplicationRecord
  KINDS = %w[added resolved reactivated onset_corrected].freeze

  # Opcional no modelo: o evento nasce ANTES do problema novo (o trigger de
  # patient_problems exige o evento da mesma transação), e a FK DEFERRABLE do
  # banco confere a existência no COMMIT.
  belongs_to :patient_problem, optional: true
  belongs_to :user
end
