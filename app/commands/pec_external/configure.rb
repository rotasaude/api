# Configuração do PEC da cidade (ADR 0035; contrato §6), só pelo maintenance,
# dentro da conexão da cidade (CityMutation#in_city). A chave HMAC é a do
# cadastro do integrador no PEC (texto opaco; docs/pesquisa/2026-10-11-pec-
# sistemas-externos.md); nunca volta em Result, log ou evento.
module PecExternal
  module Configure
    KEY_FORMAT = /\A[\x21-\x7E]{16,512}\z/
    DEFAULT_PORTS = { "https" => 443, "http" => 80 }.freeze
    MAX_ORIGIN = 255

    module_function

    def set_origin(origin:)
      normalized = origin.nil? ? nil : normalize_origin(origin)
      return Result.fail(:invalid_origin) if !origin.nil? && normalized.nil?

      setting = PecSetting.lock.first || PecSetting.new
      setting.update!(pec_origin: normalized, pec_origin_updated_at: Time.current)
      Result.ok(pec_origin: normalized)
    end

    def rotate_key(key:)
      return Result.fail(:invalid_key) unless key.is_a?(String) && key.match?(KEY_FORMAT)

      setting = PecSetting.lock.first || PecSetting.new
      setting.update!(hmac_key: key, hmac_key_updated_at: Time.current)
      Result.ok(hmac_key_configured: true)
    end

    # scheme://host[:port], https sempre e http só fora de ambiente publicado.
    def normalize_origin(raw)
      return nil unless raw.is_a?(String) && raw.strip.length.between?(1, MAX_ORIGIN)

      uri = URI.parse(raw.strip)
      schemes = Rota.deployed? ? %w[https] : %w[https http]
      return nil unless schemes.include?(uri.scheme&.downcase) && uri.host.present?
      return nil unless uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && [ "", "/" ].include?(uri.path.to_s)

      scheme = uri.scheme.downcase
      port = uri.port == DEFAULT_PORTS[scheme] ? "" : ":#{uri.port}"
      "#{scheme}://#{uri.host.downcase}#{port}"
    rescue URI::InvalidURIError
      nil
    end

    # Plataforma (contrato §7): o campo mudado, nunca o valor.
    def audit!(city_slug:, field:, maintainer_id:)
      Platform.audit("city.pec_config_changed", city_id: City.where(slug: city_slug).pick(:id), field: field,
                                                maintainer_id: maintainer_id)
    end
  end
end
