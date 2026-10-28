# Pedido de regulação (ADR 0044): o estado atual, com `version` otimista; o
# rascunho na consulta é a linha em `draft` (só vale na finalização ou no
# adendo). O andamento fica em regulation_request_events (só acréscimo; `missed`
# só ali, nunca como situação atual) e cada autorização numa linha de
# regulation_authorizations. Diagnóstico, justificativa, motivo da cor e
# observação do agendamento são cifrados com a chave da cidade; dado pessoal
# (nem o alvo) nunca sai em inspect, to_s, pretty_print nem as_json — só id,
# situação e versão.
class RegulationRequest < ApplicationRecord
  encrypts :cid10, :ciap2, :justification, :color_reason, :schedule_notes

  belongs_to :patient
  belongs_to :consultation
  belongs_to :requester_user, class_name: "User"
  belongs_to :requester_unit, class_name: "HealthUnit"
  belongs_to :addendum, class_name: "ConsultationAddendum", optional: true
  belongs_to :appointment_request, optional: true
  has_many :events, -> { order(:created_at, :id) }, class_name: "RegulationRequestEvent", inverse_of: :regulation_request,
                                                    dependent: :restrict_with_error
  has_many :authorizations, -> { order(:created_at, :id) }, class_name: "RegulationAuthorization", inverse_of: :regulation_request,
                                                            dependent: :restrict_with_error

  def effective_color = color || suggested_color

  # A autorização vigente: a última ainda não liberada (lê o que já estiver
  # carregado, para servir à lista com preload).
  def current_authorization = authorizations.reject(&:released_at).last

  # Vencido: prazo passado e ainda esperando (Desvio 5).
  def overdue?(today = Time.zone.today)
    CareRegulation::Catalog::WAITING_STATUSES.include?(status) && due_on.present? && due_on < today
  end

  def inspect = "#<RegulationRequest id=#{id} status=#{status} version=#{version}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "status" => status, "version" => version }
end
