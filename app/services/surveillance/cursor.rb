# Cursor opaco da fila da vigilância (contrato §5, K12(c)): a ordem da fila
# (vencidas, imediatas, prazo, id) não é por id, então o cursor leva os quatro
# valores de ordenação da última linha — [vencida, imediata, due_at, id] —,
# em JSON base64 url-safe. Só ids, booleanos e o prazo: nunca dado do paciente.
module Surveillance
  module Cursor
    MAX_LENGTH = 512
    TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    # values: [overdue (bool), immediate (bool), due_at (Time), id (uuid)].
    def encode(values)
      overdue, immediate, due_at, id = values
      Base64.urlsafe_encode64(JSON.generate([ overdue, immediate, due_at.utc.iso8601(6), id ]), padding: false)
    end

    # -> [overdue, immediate, due_at (Time), id] | nil (cursor inválido).
    def decode(token)
      return nil unless token.is_a?(String) && token.length.between?(1, MAX_LENGTH)

      overdue, immediate, due_at, id, *rest = JSON.parse(Base64.urlsafe_decode64(token))
      return nil unless rest.empty? && [ true, false ].include?(overdue) && [ true, false ].include?(immediate)
      return nil unless due_at.is_a?(String) && due_at.match?(TIME) && id.is_a?(String) && id.match?(UUID)

      [ overdue, immediate, Time.iso8601(due_at), id ]
    rescue ArgumentError, JSON::ParserError, TypeError
      nil
    end
  end
end
