require "base64"

# Cursor opaco do download (módulo 24b; contrato §9.3; Ruling A12):
# base64url sem padding de { v: 1, scope_digest, since, after_id }.
#   - scope_digest: o FieldSync::Scope de quando a página saiu (64 hex);
#   - since + after_id: a posição no fluxo único (tempo, id) — o tempo e o id
#     da última linha entregue (item ou lápide), ou null/null antes de
#     qualquer linha. since sempre em UTC com microssegundos.
# Só isso: nada de nome, CPF, endereço ou id de pessoa. Qualquer outra coisa
# (base64 ruim, JSON ruim, chave a mais ou a menos, v ≠ 1, valor fora da
# forma) → Invalid (422 invalid_cursor), sem dizer o quê.
module FieldSync
  module Cursor
    VERSION = 1
    KEYS = %w[v scope_digest since after_id].freeze
    RAW = /\A[A-Za-z0-9_-]{1,1024}\z/
    DIGEST = /\A[0-9a-f]{64}\z/
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    SINCE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/
    Invalid = Class.new(StandardError)

    module_function

    def encode(scope_digest:, since:, after_id:)
      payload = { v: VERSION, scope_digest: scope_digest, since: since, after_id: after_id }
      Base64.urlsafe_encode64(payload.to_json, padding: false)
    end

    # -> { scope_digest:, since: String | nil, after_id: String | nil }
    def decode(raw)
      raise Invalid unless raw.is_a?(String) && raw.match?(RAW)

      data = JSON.parse(Base64.urlsafe_decode64(raw))
      raise Invalid unless data.is_a?(Hash) && data.keys.sort == KEYS.sort && data["v"] == VERSION

      digest, since, after_id = data.values_at("scope_digest", "since", "after_id")
      raise Invalid unless digest.is_a?(String) && digest.match?(DIGEST)
      raise Invalid unless since.nil? == after_id.nil?
      raise Invalid unless since.nil? || (since.is_a?(String) && since.match?(SINCE) && after_id.is_a?(String) && after_id.match?(UUID))

      Time.iso8601(since) if since # data impossível (13º mês) → ArgumentError
      { scope_digest: digest, since: since, after_id: after_id }
    rescue ArgumentError, JSON::ParserError, EncodingError
      raise Invalid
    end
  end
end
