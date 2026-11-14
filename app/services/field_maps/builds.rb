require "net/http"

# O índice de builds públicas do Protomaps (módulo 24c, ADR 0053; Q23): uma
# lista de `{ "key": "AAAAMMDD.pmtiles", … }`. A base sai da mais recente.
# Rede fora, resposta que não é a lista esperada ou lista sem build → nil
# (quem chama registra `base_missing`); o corpo da resposta nunca vai ao log.
module FieldMaps
  module Builds
    KEY = /\A(\d{4})(\d{2})(\d{2})\.pmtiles\z/
    TIMEOUT = 15

    module_function

    # -> { key:, version: Date, url: } | nil
    def latest
      rows = JSON.parse(fetch(URI(Config.builds_index_url)))
      key = Array(rows).filter_map { |row| row["key"] if row.is_a?(Hash) && row["key"].to_s.match?(KEY) }.max
      return nil unless key

      { key: key, version: Date.new(*key.match(KEY).captures.map(&:to_i)), url: format(Config.build_url_template, key: key) }
    rescue StandardError => e
      Rails.logger.error("[field_maps.builds] index unavailable error=#{e.class.name}")
      nil
    end

    def fetch(uri)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.get(uri.request_uri)
      end
      raise "status #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end
    private_class_method :fetch
  end
end
