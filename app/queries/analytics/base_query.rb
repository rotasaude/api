# app/queries/analytics/base_query.rb
module Analytics
  # Leitura de analytics_daily_facts para uma frente (contratos §1). Soma
  # período e recorte no SQL e só então suprime (Analytics::Suppression).
  # Com `periods` vazio (nunca consolidou), as séries saem vazias; a frente
  # sem série (calibração) olha `consolidated`.
  class BaseQuery
    def initialize(params, periods:, consolidated: true)
      @params = params
      @periods = periods
      @consolidated = consolidated
    end

    private

    attr_reader :params, :periods

    def consolidated? = @consolidated

    # { [período, *chaves] => soma } de uma métrica no intervalo e nos recortes.
    def sums(metric, keys: [], filters: [])
      return {} if periods.empty?

      scoped(AnalyticsDailyFact.where(metric: metric, day: params.from..params.to), filters)
        .group(Arel.sql(params.period_sql), *keys).sum(:value)
        .to_h { |key, value| parts = Array(key); [ [ Analytics.to_date(parts.first), *parts.drop(1) ], value ] }
    end

    # { chaves => soma } do período inteiro (sem série).
    def totals(metric, keys:, filters: [])
      scoped(AnalyticsDailyFact.where(metric: metric, day: params.from..params.to), filters).group(*keys).sum(:value)
    end

    def scoped(relation, filters)
      relation = relation.where(neighborhood_id: params.neighborhood_value) if filters.include?(:neighborhood) && params.neighborhood?
      relation = relation.where(health_unit_id: params.health_unit_id) if filters.include?(:unit) && params.health_unit_id
      relation = relation.where(protocol_name: params.protocol_name) if filters.include?(:protocol) && params.protocol_name
      relation = relation.where(protocol_version: params.protocol_version) if filters.include?(:version) && params.protocol_version
      relation
    end

    # sums com uma chave → { chave => { período => soma } }.
    def split(sums)
      sums.each_with_object(Hash.new { |hash, key| hash[key] = Hash.new(0) }) do |((period, key), value), acc|
        acc[key][period] += value
      end
    end

    # sums sem chave (ou com chaves a juntar) → { período => soma }.
    def flat(sums)
      sums.each_with_object(Hash.new(0)) { |((period, *), value), acc| acc[period] += value }
    end

    def series(by_period) = periods.map { |period| Suppression.cell(by_period.fetch(period, 0)) }

    # Total do grupo: uma célula oculta na série esconde o total da linha.
    def row(by_period) = { series: series(by_period), total: Suppression.group(by_period.values.sum, by_period.values) }

    def ordered(rows, name:) = rows.sort_by { |row| [ -Suppression.sort_value(row[:total]), row[name].to_s ] }

    # Todas as unidades da cidade, para o seletor (contratos §1): o analyst
    # não lê /attendance/units. Independe do recorte e do período.
    def units
      HealthUnit.order(:name).map { |unit| { health_unit_id: unit.id, name: unit.name, active: unit.active } }
    end

    def unit_names(ids) = HealthUnit.where(id: ids.compact).pluck(:id, :name).to_h
  end
end
