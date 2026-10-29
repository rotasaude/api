# Cursor opaco da fila do regulador (contrato §4, §13 G2): a ordem (vencidos,
# cor, data do pedido, id) não é por id, então o cursor leva o dia usado na
# conta de "vencido" e os quatro valores de ordenação da última linha —
# [dia, vencido (0|1), rank da cor (0..3), requested_at, id] —, em JSON base64
# url-safe. Com o dia dentro, a página 2 sai certa na virada do dia. Só ids,
# números, datas: nunca dado do paciente. Tupla de outro tamanho (inclusive a
# de 3 elementos do plano antigo) é inválida.
module CareRegulation
  module Cursor
    class Invalid < StandardError; end

    MAX_LENGTH = 512
    DAY = /\A\d{4}-\d{2}-\d{2}\z/
    TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    # Cursor das listas em ordem `requested_at ASC, id ASC` (os devolvidos):
    # [requested_at, id], mesma codificação. Tupla da fila (5) é inválida aqui
    # e a daqui (2) é inválida na fila.
    def encode_page(requested_at, id)
      Base64.urlsafe_encode64(JSON.generate([ requested_at.utc.iso8601(6), id ]), padding: false)
    end

    # -> [Time, String] | levanta Cursor::Invalid.
    def decode_page(raw)
      raise Invalid unless raw.is_a?(String) && raw.length.between?(1, MAX_LENGTH)

      tuple = JSON.parse(Base64.urlsafe_decode64(raw))
      raise Invalid unless tuple.is_a?(Array) && tuple.size == 2

      requested_at, id = tuple
      raise Invalid unless requested_at.is_a?(String) && requested_at.match?(TIME) && id.is_a?(String) && id.match?(UUID)

      [ Time.iso8601(requested_at), id ]
    rescue ArgumentError, JSON::ParserError, TypeError
      raise Invalid
    end

    # tuple: [dia (Date ou "AAAA-MM-DD"), overdue_key, rank, requested_at (Time), id (uuid)].
    def encode(tuple)
      day, overdue_key, rank, requested_at, id = tuple
      Base64.urlsafe_encode64(JSON.generate([ Date.iso8601(day.to_s).iso8601, overdue_key, rank, requested_at.utc.iso8601(6), id ]), padding: false)
    end

    # -> [Date, Integer, Integer, Time, String] | levanta Cursor::Invalid.
    def decode(raw)
      raise Invalid unless raw.is_a?(String) && raw.length.between?(1, MAX_LENGTH)

      tuple = JSON.parse(Base64.urlsafe_decode64(raw))
      raise Invalid unless tuple.is_a?(Array) && tuple.size == 5

      day, overdue_key, rank, requested_at, id = tuple
      raise Invalid unless day.is_a?(String) && day.match?(DAY) && [ 0, 1 ].include?(overdue_key) && overdue_key.is_a?(Integer)
      raise Invalid unless rank.is_a?(Integer) && Catalog::COLOR_RANK.value?(rank)
      raise Invalid unless requested_at.is_a?(String) && requested_at.match?(TIME) && id.is_a?(String) && id.match?(UUID)

      [ Date.iso8601(day), overdue_key, rank, Time.iso8601(requested_at), id ]
    rescue ArgumentError, JSON::ParserError, TypeError
      raise Invalid
    end
  end
end
