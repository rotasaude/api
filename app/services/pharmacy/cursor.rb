# Cursor opaco das listas da farmácia (ADR 0045): lista de textos (ids, datas
# ISO) em JSON base64 url-safe. Posições: [location_id, catalog_item_id];
# transferências, ajustes e dispensações: [iso8601(6), id]; extrato:
# [recorded_at, created_at, id]. Só ids e datas: nunca dado do paciente.
# Inválido → nil (o controlador responde invalid_cursor).
module Pharmacy
  module Cursor
    MAX_LENGTH = 512
    MAX_PARTS = 4

    module_function

    def encode(parts)
      Base64.urlsafe_encode64(JSON.generate(Array(parts).map(&:to_s)), padding: false)
    end

    # -> Array<String> | nil
    def decode(raw)
      return nil unless raw.is_a?(String) && raw.length.between?(1, MAX_LENGTH)

      parts = JSON.parse(Base64.urlsafe_decode64(raw))
      return nil unless parts.is_a?(Array) && parts.size.between?(1, MAX_PARTS) && parts.all?(String)

      parts
    rescue ArgumentError, JSON::ParserError, TypeError
      nil
    end
  end
end
