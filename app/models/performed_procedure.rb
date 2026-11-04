# Procedimento realizado (ADR 0039; spec §4): só acréscimo no conteúdo
# clínico; a crítica (instrumento, faturável, motivos) é recalculada no
# fechamento e o estado só vai de recorded a cancelled (trigger). Exatamente
# um estabelecimento: unidade de saúde ou laboratório municipal. O motivo do
# cancelamento é cifrado com a chave da cidade e nunca aparece no inspect.
class PerformedProcedure < ApplicationRecord
  # ADR 0048: `tfd` — uma linha por ajuda de custo (tfd_allowance_id único),
  # com o trecho de rastro (tfd_leg_id). ADR 0049: `psychosocial` — uma linha
  # por ação do CAPS BPA-C ou BPA-I (psychosocial_action_id único); a BPA-C da
  # ação de equipe não tem paciente (ck_performed_procedures_patient).
  SOURCES = %w[attendance consultation lab_report manual tfd psychosocial].freeze
  INSTRUMENTS = %w[bpa_i bpa_c not_bpa].freeze
  CHARACTERS = %w[elective urgent].freeze
  STATUSES = %w[recorded cancelled].freeze
  # Quantidade aceita (ck_performed_procedures_quantity; BPA: 3 dígitos).
  QUANTITY = (1..999)

  encrypts :cancel_reason

  belongs_to :patient, optional: true
  belongs_to :health_unit, optional: true
  belongs_to :exam_provider, optional: true
  belongs_to :professional_user, class_name: "User"
  belongs_to :recorded_by_user, class_name: "User", optional: true
  belongs_to :cancelled_by_user, class_name: "User", optional: true
  belongs_to :attendance, optional: true
  belongs_to :consultation, optional: true
  belongs_to :lab_report_item, optional: true
  belongs_to :tfd_allowance, optional: true
  belongs_to :tfd_leg, optional: true
  belongs_to :psychosocial_action, optional: true
  belongs_to :billing_period, optional: true
  belongs_to :billing_export, optional: true

  scope :recorded, -> { where(status: "recorded") }
  # Módulo 31 (P45, P51): fora a linha do CAPS — a da fonte `psychosocial` e a
  # lançada numa unidade `caps` — nas leituras gerais (linha do tempo da UBS,
  # boas práticas do 23). A linha do laboratório tem health_unit_id nulo.
  scope :outside_caps, lambda {
    where.not(source: "psychosocial")
      .where("performed_procedures.health_unit_id IS NULL OR performed_procedures.health_unit_id NOT IN " \
             "(SELECT health_units.id FROM health_units WHERE health_units.kind = 'caps')")
  }

  def inspect = "#<PerformedProcedure id=#{id} source=#{source} status=#{status} billable=#{billable}>"
end
