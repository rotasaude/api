# O exame (ADR 0036): identidade fixa e um cache da situação que só muda com
# um evento da trilha na mesma transação (trigger exam_orders_guard). Use
# Exams::Transition/Exams::Escalate — nunca update! direto.
class ExamOrder < ApplicationRecord
  STATUSES = %w[awaiting_authorization denied awaiting_schedule scheduled collected resulted acknowledged cancelled].freeze
  ORIGINS = %w[consultation reception_guide pec lab_reception].freeze
  PRIORITIES = %w[routine urgent].freeze
  OPEN_STATUSES = %w[awaiting_authorization awaiting_schedule scheduled collected resulted].freeze

  encrypts :requester_name
  encrypts :requester_cns

  belongs_to :patient
  belongs_to :unit, class_name: "HealthUnit"
  belongs_to :requester_user, class_name: "User", optional: true
  belongs_to :exam_provider, optional: true
  belongs_to :consultation_exam_request, optional: true
  belongs_to :guide_file, class_name: "ExamFile", optional: true
  belongs_to :created_by_user, class_name: "User", optional: true
  # Sem `dependent:`: o pedido nunca some, e quem recusa o DELETE é o banco
  # (exam_orders_guard), não um callback que o update_all/delete_all pularia.
  has_many :events, -> { order(:occurred_at, :created_at, :id) }, class_name: "ExamOrderEvent", inverse_of: :exam_order
  has_one :result, class_name: "ExamResult", inverse_of: :exam_order
  has_one :lab_item, class_name: "LabRequisitionItem", inverse_of: :exam_order

  def catalog_item = ExamCatalogItem.find_by(sigtap_code: sigtap_code)
  def escalated? = escalated_at.present?
  def requester_display_name = requester_user ? Screenings::Json.staff_name(requester_user) : requester_name

  # Atraso pelo prazo gravado na transição, em dias corridos no fuso da cidade.
  def overdue(today: Time.zone.today)
    return nil unless stage && stage_due_on && OPEN_STATUSES.include?(status) && today > stage_due_on

    { stage: stage, due_on: stage_due_on, days_late: (today - stage_due_on).to_i }
  end

  def inspect = "#<ExamOrder id=#{id} status=#{status} stage=#{stage} origin=#{origin}>"
end
