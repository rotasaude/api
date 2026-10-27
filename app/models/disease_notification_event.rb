# Andamento da notificação (ADR 0043): só acréscimo (trigger). O motivo é
# cifrado e, como todo dado pessoal, não sai em inspect, to_s, pretty_print
# nem as_json (R18).
class DiseaseNotificationEvent < ApplicationRecord
  encrypts :reason

  belongs_to :notification, class_name: "DiseaseNotification", inverse_of: :events
  belongs_to :by_user, class_name: "User", optional: true

  def inspect = "#<DiseaseNotificationEvent id=#{id} notification_id=#{notification_id} status=#{status}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "notification_id" => notification_id, "status" => status }
end
