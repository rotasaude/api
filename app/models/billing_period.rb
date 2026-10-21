# Competência de um estabelecimento faturante (ADR 0039; spec §4): nasce
# aberta com a primeira produção; fechar gera a versão seguinte do arquivo;
# reabrir exige motivo (cifrado). Estabelecimento e competência imutáveis.
class BillingPeriod < ApplicationRecord
  STATUSES = %w[open closed].freeze

  encrypts :reopened_reason

  belongs_to :health_unit, optional: true
  belongs_to :exam_provider, optional: true
  belongs_to :closed_by_user, class_name: "User", optional: true
  belongs_to :reopened_by_user, class_name: "User", optional: true
  has_many :procedures, class_name: "PerformedProcedure", dependent: :restrict_with_error
  has_many :exports, class_name: "BillingExport", dependent: :restrict_with_error

  def closed? = status == "closed"
  def inspect = "#<BillingPeriod id=#{id} competence=#{competence} status=#{status} version=#{version}>"
end
