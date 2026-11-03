# Processo de Tratamento Fora de Domicílio (ADR 0048): estado atual com
# `version` otimista; o andamento fica em tfd_case_events (só acréscimo). O
# laudo (`report`: SIGTAP, CID, justificativa, acompanhante, modal) é um JSON
# cifrado com a chave da cidade — a lista e os eventos nunca o leem. Nunca é
# apagado (trigger). Dado do paciente nunca sai em inspect, to_s,
# pretty_print nem as_json — só o id.
class TfdCase < ApplicationRecord
  serialize :report, coder: JSON
  encrypts :report

  belongs_to :patient
  belongs_to :consultation, optional: true
  belongs_to :regulation_request, optional: true
  belongs_to :requester_user, class_name: "User"
  belongs_to :transport_destination
  belongs_to :care_provider, optional: true
  has_many :tfd_case_events, -> { order(:created_at, :id) }, inverse_of: :tfd_case, dependent: :restrict_with_error
  has_many :tfd_legs, -> { order(:date, :created_at) }, inverse_of: :tfd_case, dependent: :restrict_with_error
  has_many :tfd_allowances, inverse_of: :tfd_case, dependent: :restrict_with_error
  has_many :tfd_payments, -> { order(:paid_on, :created_at) }, inverse_of: :tfd_case, dependent: :restrict_with_error
  has_one :tfd_accountability, inverse_of: :tfd_case, dependent: :restrict_with_error
  has_many :transport_trip_passengers, inverse_of: :tfd_case, dependent: :restrict_with_error

  def inspect = "#<TfdCase id=#{id} status=#{status}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
