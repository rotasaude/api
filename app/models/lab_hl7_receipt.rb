# Recibo da mensagem HL7 aceita (ADR 0037; contrato B10): bruto cifrado, uma vez por mensagem.
class LabHl7Receipt < ApplicationRecord
  encrypts :raw

  belongs_to :lab_middleware_token

  def inspect = "#<LabHl7Receipt id=#{id} message_type=#{message_type}>"
end
