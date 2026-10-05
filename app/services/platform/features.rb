# Interruptores de funcionalidade por cidade (ADR 0028; spec 2026-10-05 §3.1;
# contratos §2). O catálogo mora no código; o estado por cidade, em
# city_features (plataforma). `requires` diz o que precisa existir para a
# funcionalidade ser UTILIZÁVEL; ligado e utilizável são coisas diferentes.
module Platform
  module Features
    Entry = Data.define(:key, :description, :requires)

    CATALOG = [
      Entry.new(key: "ledi_export",
                description: "Exportação contínua da produção (LEDI APS) para o PEC da cidade",
                requires: %w[record_mode pec_url ibge_code credential:ledi]),
      Entry.new(key: "cadsus_lookup",
                description: "Consulta ao CADSUS na validação presencial",
                requires: %w[credential:cadsus])
    ].freeze

    KEYS = CATALOG.map(&:key).freeze
    class UnknownFeature < StandardError; end

    UNREACHABLE = [ "city_unreachable" ].freeze

    module_function

    def find(key) = CATALOG.find { |entry| entry.key == key.to_s }

    def find!(key) = find(key) || raise(UnknownFeature, "interruptor fora do catálogo: #{key}")

    def enabled?(city, key)
      find!(key)
      CityFeature.exists?(city_id: city.id, key: key.to_s, enabled: true)
    end

    # Para a sessão (contratos §1): só a plataforma, sem abrir a cidade.
    def enabled_keys(city)
      CityFeature.where(city_id: city.id, enabled: true, key: KEYS).order(:key).distinct.pluck(:key)
    end

    # record_mode e pec_url relidos por id: Current.city sai do CityCatalog, com
    # cache de 30 s (desvio 4).
    def settings(city)
      record_mode, pec_url = City.where(id: city.id).pick(:record_mode, :pec_url)
      { record_mode: record_mode, pec_url: pec_url }
    end

    # O que mora no banco da cidade, numa conexão só. nil = não deu para ler
    # (cidade não ativa não é discada; inalcançável vira nil, nunca exceção).
    def city_state(city)
      return nil unless city.servable?

      CityConnection.with(city) do
        { credentials: IntegrationCredential.pluck(:kind, :last_check_status).to_h,
          ibge_code: CityProfile.current&.ibge_code }
      end
    rescue *Maintenance::CityConnectionErrors::CLASSES, ActiveRecord::StatementInvalid
      nil
    end

    def missing(city, key, state: :load)
      entry = find!(key)
      state = city_state(city) if state == :load
      return UNREACHABLE.dup if state.nil?

      platform = settings(city)
      entry.requires.filter_map { |requirement| missing_for(requirement, platform, state) }
    end

    def usable?(city, key, state: :load) = enabled?(city, key) && missing(city, key, state: state).empty?

    def summary(city, state: :load)
      state = city_state(city) if state == :load
      rows = CityFeature.where(city_id: city.id).index_by(&:key)
      emails = Maintainer.where(id: rows.values.map(&:changed_by_maintainer_id)).pluck(:id, :email_address).to_h

      CATALOG.map do |entry|
        row = rows[entry.key]
        lacking = missing(city, entry.key, state: state)
        enabled = row&.enabled || false
        { key: entry.key, description: entry.description, enabled: enabled, usable: enabled && lacking.empty?,
          missing: lacking, changed_at: row&.changed_at, changed_by: row && emails[row.changed_by_maintainer_id] }
      end
    end

    def set!(city:, key:, enabled:, maintainer:)
      find!(key)
      PlatformRecord.transaction do
        feature = CityFeature.lock.find_or_initialize_by(city_id: city.id, key: key.to_s)
        next feature if feature.persisted? && feature.enabled == enabled

        feature.update!(enabled: enabled, changed_by_maintainer: maintainer, changed_at: Time.current)
        Platform.audit("city.feature_changed", city_id: city.id, key: key.to_s, enabled: enabled,
                                               maintainer_id: maintainer.id)
        feature
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def missing_for(requirement, platform, state)
      case requirement
      when "record_mode" then "record_mode_off" if platform[:record_mode] == "off"
      when "pec_url" then "pec_url_missing" if platform[:pec_url].blank?
      when "ibge_code" then "ibge_code_missing" if state[:ibge_code].blank?
      when /\Acredential:(\w+)\z/
        kind = Regexp.last_match(1)
        if !state[:credentials].key?(kind) then "credential_missing:#{kind}"
        elsif state[:credentials][kind] == "unauthorized" then "credential_unauthorized:#{kind}"
        end
      else
        raise ArgumentError, "pré-requisito desconhecido no catálogo: #{requirement}"
      end
    end
  end
end
