# Notificação compulsória (ADR 0043): o estado atual, com `version` otimista; o
# andamento fica em disease_notification_events (imutável). A ficha (form) é
# JSON cifrado com a chave da cidade, e dado pessoal nunca sai em inspect,
# to_s, pretty_print nem as_json (R18) — só id, estado, versão e a unidade.
class DiseaseNotification < ApplicationRecord
  serialize :form, coder: JSON
  encrypts :form

  belongs_to :patient
  belongs_to :health_unit
  belongs_to :notifier_user, class_name: "User", optional: true
  belongs_to :consultation, optional: true
  belongs_to :addendum, class_name: "ConsultationAddendum", optional: true
  belongs_to :neighborhood, optional: true
  has_many :events, -> { order(:created_at, :id) }, class_name: "DiseaseNotificationEvent", foreign_key: :notification_id,
                                                    inverse_of: :notification, dependent: :restrict_with_error

  scope :open_notifications, -> { where(status: Surveillance::Catalog::OPEN_STATUSES) }
  # Vencida: prazo passado e situação possible/notified. A ÚNICA definição em
  # SQL: a fila (Surveillance::Queue: contadores, filtro e a coluna q_overdue) e
  # os alertas diários usam este fragmento; #overdue? é o espelho em Ruby.
  def self.overdue_sql(now)
    sanitize_sql_array([ "(disease_notifications.due_at < ? AND disease_notifications.status IN (?))",
                         now, Surveillance::Catalog::OVERDUE_STATUSES ])
  end
  scope :overdue_at, ->(now) { where(overdue_sql(now)) }

  # Só `possible` e `notified` atrasam: a investigação já começou.
  def overdue?(now = Time.current)
    Surveillance::Catalog::OVERDUE_STATUSES.include?(status) && due_at < now
  end

  def inspect = "#<DiseaseNotification id=#{id} status=#{status} version=#{version}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "status" => status, "version" => version, "health_unit_id" => health_unit_id }
end
