# GET /city_production (contratos §4.3 e §8): cidades ativas com record_mode fora
# de off, competência corrente e anterior (corrente primeiro) no fuso de cada
# cidade, contagens publicadas (zero quando ainda não há linha) e prazo/alerta
# recalculados agora. `sending` é contagem própria; `pending` não o inclui (R18).
# `deadline_estimated_on` só quando difere da data oficial (R16). Só o banco de
# plataforma.
module Ledi
  module CityProductionQuery
    PLATFORM_ZONE = "America/Sao_Paulo"
    COUNTS = %i[accepted rejected pending sending failed].freeze
    ZERO = COUNTS.index_with(0).freeze

    module_function

    def call(now: Time.current)
      cities = City.where(status: "active").where.not(record_mode: "off").order(:name).to_a
      summaries = CityProductionSummary.where(city_id: cities.map(&:id)).group_by(&:city_id)
      { cities: cities.map { |city| city_entry(city, summaries.fetch(city.id, []), now) }, terminology: terminology(now) }
    end

    def city_entry(city, rows, now)
      today = now.in_time_zone(city.time_zone).to_date
      by_competence = rows.index_by(&:competence)
      competences = [ Ledi::Deadline.current(today), Ledi::Deadline.previous(today) ].map do |competence|
        row = by_competence[competence]
        counts = row ? COUNTS.to_h { |k| [ k, row.public_send(k) ] } : ZERO
        competence_entry(competence, counts, today, city.record_mode)
      end
      { slug: city.slug, name: city.name, record_mode: city.record_mode, competences: competences }
    end

    def competence_entry(competence, counts, today, record_mode)
      left = Ledi::Deadline.business_days_left(competence, today: today)
      official = Ledi::Deadline.on(competence)
      estimated = Ledi::Deadline.estimated_on(competence)
      entry = { competence: competence, deadline_on: official.iso8601 }
      entry[:deadline_estimated_on] = estimated.iso8601 if estimated != official
      entry.merge(business_days_left: left, **counts,
                  alert: Ledi::Alert.level(counts: counts, business_days_left: left, record_mode: record_mode))
    end

    # Regra do alerta de SIGTAP é da fundação (Terminology::SigtapStatus: dia >= 5
    # em America/Sao_Paulo sem release ativa da competência corrente); aqui só
    # renomeia `alert` para o campo do contrato.
    def terminology(now)
      status = Terminology::SigtapStatus.call(today: now.in_time_zone(PLATFORM_ZONE).to_date)
      { sigtap_current_competence: status[:sigtap_current_competence], sigtap_imported: status[:sigtap_imported],
        sigtap_alert: status[:alert] }
    end
  end
end
