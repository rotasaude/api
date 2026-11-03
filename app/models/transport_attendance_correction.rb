# Correção da presença depois do fechamento (ADR 0048, Desvio 9): uma linha
# por campo mudado, com o motivo cifrado com a chave da cidade. Imutável
# (trigger; a re-cifra regrava só o motivo, e a exclusão LGPD o troca uma vez
# pelo texto fixo, sob with_erasure).
class TransportAttendanceCorrection < ApplicationRecord
  encrypts :reason

  belongs_to :transport_trip_passenger, inverse_of: :transport_attendance_corrections
  belongs_to :by_user, class_name: "User"

  # A única porta para regravar o motivo fora da re-cifra: a exclusão LGPD
  # (Transport::Anonymize) troca o texto livre pelo fixo, uma vez, antes de
  # anonimizar o passageiro (o trigger lê rota.transport_erasure). Molde do
  # TransportTripPassenger.with_attendance_correction: savepoint próprio e o
  # flag volta a 'off' no sucesso (o SET LOCAL sobreviveria ao RELEASE).
  def self.with_erasure
    connection = ApplicationRecord.connection
    ApplicationRecord.transaction(requires_new: true) do
      connection.execute("SET LOCAL rota.transport_erasure = 'on'")
      failed = false
      begin
        yield
      rescue Exception # qualquer saída por erro (só marca e relança)
        failed = true
        raise
      ensure
        connection.execute("SET LOCAL rota.transport_erasure = 'off'") unless failed
      end
    end
  end

  def inspect = "#<TransportAttendanceCorrection id=#{id} field=#{field}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
