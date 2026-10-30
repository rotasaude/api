# Cursor opaco da lista de eventos do odontograma (contrato §16 O13): a lista
# sai do mais novo para o mais velho por (recorded_at, seq), então o cursor leva
# os dois da última linha — [recorded_at iso8601(6), seq] —, em JSON base64
# url-safe. Só data e número: nunca dado clínico. Qualquer outra forma é inválida.
module DentalCare
  module EventCursor
    class Invalid < StandardError; end

    MAX_LENGTH = 256
    TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/
    MAX_SEQ = 2**63 - 1

    module_function

    def encode(recorded_at, seq)
      Base64.urlsafe_encode64(JSON.generate([ recorded_at.utc.iso8601(6), seq ]), padding: false)
    end

    # -> [Time, Integer] | levanta Invalid.
    def decode(raw)
      raise Invalid unless raw.is_a?(String) && raw.length.between?(1, MAX_LENGTH)

      tuple = JSON.parse(Base64.urlsafe_decode64(raw))
      raise Invalid unless tuple.is_a?(Array) && tuple.size == 2

      at, seq = tuple
      raise Invalid unless at.is_a?(String) && at.match?(TIME) && seq.is_a?(Integer) && seq.between?(1, MAX_SEQ)

      [ Time.iso8601(at), seq ]
    rescue ArgumentError, JSON::ParserError, TypeError
      raise Invalid
    end
  end
end
