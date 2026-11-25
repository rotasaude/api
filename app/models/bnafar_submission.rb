# Remessa diária à BNAFAR (módulo 27b; contrato §3; Q8; R10): uma por (dia de
# referência, assunto, ambiente). A situação agrega as partes `post`; as partes
# `put` (correção) e `delete` (estorno) têm ciclo próprio e nunca reabrem a
# remessa. Nunca some; a situação só anda para a frente (trigger).
class BnafarSubmission < ApplicationRecord
  has_many :batches, class_name: "BnafarBatch", inverse_of: :bnafar_submission
  has_many :records, class_name: "BnafarRecord", inverse_of: :bnafar_submission

  def inspect = "#<BnafarSubmission id=#{id} reference_on=#{reference_on} subject=#{subject} environment=#{environment} status=#{status}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
end
