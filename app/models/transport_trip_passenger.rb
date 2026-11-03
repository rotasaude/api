# Passageiro da viagem (ADR 0048): paciente, parada de embarque, destino
# (município) e, cifrados com a chave da cidade, prestador, endereço,
# acompanhante, nota da exceção e motivo da retirada. Uma origem (regulação,
# agendamento, TFD, série) ou a exceção com motivo (CHECK). Sem dado clínico.
# Nunca some (trigger): retirar é `removed_at`, uma vez; a presença congela
# fora de `in_progress`, salvo sob with_attendance_correction; a anonimização
# (LGPD) só anula as cifradas, uma vez. Dado do paciente nunca sai em inspect,
# to_s, pretty_print nem as_json — só o id.
class TransportTripPassenger < ApplicationRecord
  encrypts :provider_name, :address, :companion_name, :companion_document, :companion_reason, :exception_note, :remove_reason

  belongs_to :transport_trip, inverse_of: :transport_trip_passengers
  belongs_to :patient
  belongs_to :transport_trip_stop, inverse_of: :transport_trip_passengers
  belongs_to :transport_destination
  belongs_to :regulation_request, optional: true
  belongs_to :appointment, optional: true
  belongs_to :tfd_case, optional: true
  belongs_to :transport_series, optional: true
  belongs_to :added_by_user, class_name: "User", optional: true
  belongs_to :removed_by_user, class_name: "User", optional: true
  has_many :transport_attendance_corrections, inverse_of: :transport_trip_passenger, dependent: :restrict_with_error
  has_many :transport_trip_notices, inverse_of: :transport_trip_passenger, dependent: :restrict_with_error

  scope :active, -> { where(removed_at: nil) }

  # A única porta para mudar a presença fora de `in_progress` (o trigger lê
  # rota.transport_correction; só o Transport::CorrectAttendance, que grava
  # transport_attendance_corrections). Mesmo molde do
  # Consultation.with_draft_admin: savepoint próprio; no sucesso o SET LOCAL
  # sobreviveria ao RELEASE até o fim da transação externa, por isso volta a
  # 'off' na mão; no erro, o ROLLBACK TO SAVEPOINT o desfaz (e o SET
  # levantaria por cima do erro real).
  def self.with_attendance_correction
    connection = ApplicationRecord.connection
    ApplicationRecord.transaction(requires_new: true) do
      connection.execute("SET LOCAL rota.transport_correction = 'on'")
      failed = false
      begin
        yield
      rescue Exception # qualquer saída por erro (só marca e relança)
        failed = true
        raise
      ensure
        connection.execute("SET LOCAL rota.transport_correction = 'off'") unless failed
      end
    end
  end

  def removed? = removed_at.present?

  def inspect = "#<TransportTripPassenger id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
