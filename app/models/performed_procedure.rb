# Procedimento realizado (ADR 0039; spec §4): só acréscimo no conteúdo
# clínico; a crítica (instrumento, faturável, motivos) é recalculada no
# fechamento e o estado só vai de recorded a cancelled (trigger). Exatamente
# um estabelecimento: unidade de saúde ou laboratório municipal. O motivo do
# cancelamento é cifrado com a chave da cidade e nunca aparece no inspect.
class PerformedProcedure < ApplicationRecord
  SOURCES = %w[attendance consultation lab_report manual].freeze
  INSTRUMENTS = %w[bpa_i bpa_c not_bpa].freeze
  CHARACTERS = %w[elective urgent].freeze
  STATUSES = %w[recorded cancelled].freeze

  encrypts :cancel_reason

  belongs_to :patient
  belongs_to :health_unit, optional: true
  belongs_to :exam_provider, optional: true
  belongs_to :professional_user, class_name: "User"
  belongs_to :recorded_by_user, class_name: "User", optional: true
  belongs_to :cancelled_by_user, class_name: "User", optional: true
  belongs_to :attendance, optional: true
  belongs_to :consultation, optional: true
  belongs_to :lab_report_item, optional: true
  belongs_to :billing_period, optional: true
  belongs_to :billing_export, optional: true

  scope :recorded, -> { where(status: "recorded") }

  def inspect = "#<PerformedProcedure id=#{id} source=#{source} status=#{status} billable=#{billable}>"
end
