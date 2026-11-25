# Interruptor do envio ao SI-BNAFAR (módulo 27b, Valor 2). Leitura pura: lê
# os interruptores da plataforma, nunca grava, e roda fora da transação da
# cidade (o resultado vai como argumento: `bnafar_required:`, `domains:`).
module Bnafar
  module Gate
    KEY = "bnafar".freeze
    DOMAIN_KEYS = {
      Stock::Domain::MEDICATION => "bnafar_medications",
      Stock::Domain::VECTOR_CONTROL => "bnafar_vector_supplies",
      Stock::Domain::IMMUNOBIOLOGICAL => "bnafar_vaccines"
    }.freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end

    # Domínios cujo interruptor está utilizável (Q6), com o bnafar utilizável.
    def domains(city)
      return [] unless usable?(city)

      DOMAIN_KEYS.select { |_domain, key| Platform::Features.usable?(city, key) }.keys
    end

    # Os de `domains(city)` ligados (bnafar e domínio) até o fim do dia `day`
    # no fuso da cidade: ligar vale a partir do dia seguinte (§1).
    def domains_through(city, day)
      current = domains(city)
      return [] if current.empty?

      changed = CityFeature.where(city_id: city.id, key: [ KEY, *DOMAIN_KEYS.values ]).pluck(:key, :changed_at).to_h
      cutoff = (day + 1).in_time_zone(ActiveSupport::TimeZone[city.time_zone]).beginning_of_day
      before = ->(key) { changed[key].present? && changed[key] < cutoff }
      return [] unless before.call(KEY)

      current.select { |domain| before.call(DOMAIN_KEYS.fetch(domain)) }
    end

    def required_for?(city, location)
      domains(city).include?(Stock::Domain.for(location))
    end
  end
end
