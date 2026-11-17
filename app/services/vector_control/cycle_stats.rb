# Números do ciclo de trabalho por bairro (módulo 35a, ADR 0054; contrato §5;
# Q8, D-6). O bairro do imóvel é o da versão atual do 24a. Por bairro:
#   - to_visit: domicílios ativos em microárea ativa;
#   - visited: domicílios com inspeção válida (visita não retirada) com
#     occurred_at no período do ciclo (dias da cidade, os dois inclusive);
#   - worked, closed, refused, vacant: os visitados pela situação da última
#     inspeção do ciclo (somam visited);
#   - recovered: os visitados com alguma inspeção `recovered` no ciclo;
#   - pending_percent: (closed + refused) ÷ visited × 100, uma casa; nil sem
#     visitados;
#   - registered_households: domicílios ativos do bairro (cobertura do
#     cadastro, decisão 7).
# Três consultas, qualquer que seja o tamanho do ciclo; só contagens, nunca
# imóvel nem pessoa. A Task 13 (o relatório `situations`) reusa, também
# agrupado pela classe do imóvel (by_property_class: o tipo de imóvel da
# versão atual pelo Catalog::PROPERTY_CLASSES, com as mesmas três consultas).
module VectorControl
  module CycleStats
    module_function

    # -> [{ neighborhood_id:, to_visit:, visited:, worked:, closed:, refused:, vacant:, recovered:, pending_percent:,
    #       registered_households: }], na ordem de neighborhood_ids.
    def for(cycle:, neighborhood_ids:)
      ids = neighborhood_ids.uniq
      return [] if ids.empty?

      by_key = grouped(cycle, ids, "neighborhood_id")
      ids.map { |id| { neighborhood_id: id }.merge(summary(by_key.fetch(id) { Hash.new(0) })) }
    end

    # -> [{ property_class:, <os números do `for`> }] na ordem de
    # Catalog::PROPERTY_CLASSES, só dos imóveis dos bairros dados.
    def by_property_class(cycle:, neighborhood_ids:)
      ids = neighborhood_ids.uniq
      by_type = ids.empty? ? {} : grouped(cycle, ids, "property_type")
      Catalog::PROPERTY_CLASSES.map do |klass, types|
        sums = types.each_with_object(Hash.new(0)) do |type, total|
          by_type.fetch(type, {}).each { |key, value| total[key] += value }
        end
        { property_class: klass }.merge(summary(sums))
      end
    end

    # { valor da coluna `key` da versão atual => { contagens } }.
    def grouped(cycle, ids, key)
      current = HouseholdVersion.joins(household: :micro_area).where("household_versions.version = households.version")
                                .where(neighborhood_id: ids, households: { status: "active" })
      result = Hash.new { |hash, value| hash[value] = Hash.new(0) }
      current.group(key).count.each { |value, count| result[value][:registered_households] = count }
      current.where(micro_areas: { active: true }).group(key).count.each { |value, count| result[value][:to_visit] = count }
      visits_by(cycle, ids, key).each { |value, stats| stats.each { |name, count| result[value][name] += count } }
      result
    end

    def summary(stats)
      visited = stats[:visited]
      { to_visit: stats[:to_visit], visited: visited, worked: stats["worked"], closed: stats["closed"],
        refused: stats["refused"], vacant: stats["vacant"], recovered: stats[:recovered],
        pending_percent: visited.zero? ? nil : ((stats["closed"] + stats["refused"]) * 100.0 / visited).round(1),
        registered_households: stats[:registered_households] }
    end

    # { neighborhood_id => { visited:, recovered:, "<situação>" => n } } pela
    # última inspeção válida de cada domicílio no período, agregada no banco:
    # um DISTINCT ON por domicílio (a última pela hora da visita, created_at e
    # id), com bool_or(recovered) sobre o período inteiro do domicílio, e
    # depois GROUP BY (bairro, situação) — poucas linhas por bairro, nenhuma
    # por inspeção.
    def visits_by_neighborhood(cycle, ids) = visits_by(cycle, ids, "neighborhood_id")

    # O mesmo, agrupado pela coluna `key` (neighborhood_id ou property_type)
    # da versão atual do domicílio.
    def visits_by(cycle, ids, key)
      column = { "neighborhood_id" => "neighborhood_id", "property_type" => "property_type" }.fetch(key)
      period = cycle.starts_on.beginning_of_day...(cycle.ends_on + 1).beginning_of_day
      last = VectorInspection.valid_inspections
                             .joins("JOIN households cycle_households ON cycle_households.id = vector_inspections.household_id")
                             .joins("JOIN household_versions cycle_versions ON cycle_versions.household_id = cycle_households.id " \
                                    "AND cycle_versions.version = cycle_households.version")
                             .where(home_visits: { occurred_at: period })
                             .where("cycle_versions.neighborhood_id IN (?)", ids)
                             .select("DISTINCT ON (vector_inspections.household_id) cycle_versions.#{column} AS group_key",
                                     "vector_inspections.situation AS situation",
                                     "bool_or(vector_inspections.recovered) OVER (PARTITION BY vector_inspections.household_id) AS recovered")
                             .reorder(Arel.sql("vector_inspections.household_id, home_visits.occurred_at DESC, " \
                                               "vector_inspections.created_at DESC, vector_inspections.id DESC"))
      rows = VectorInspection.unscoped.from(last, :last_inspections)
                             .group("last_inspections.group_key", "last_inspections.situation")
                             .pluck("last_inspections.group_key", "last_inspections.situation", Arel.sql("count(*)"),
                                    Arel.sql("count(*) FILTER (WHERE last_inspections.recovered)"))
      rows.each_with_object({}) do |(value, situation, count, recovered), map|
        stats = (map[value] ||= Hash.new(0))
        stats[:visited] += count
        stats[situation] += count
        stats[:recovered] += recovered
      end
    end
  end
end
