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
# imóvel nem pessoa. A Task 13 (o relatório `situations`) reusa.
module VectorControl
  module CycleStats
    module_function

    # -> [{ neighborhood_id:, to_visit:, visited:, worked:, closed:, refused:, vacant:, recovered:, pending_percent:,
    #       registered_households: }], na ordem de neighborhood_ids.
    def for(cycle:, neighborhood_ids:)
      ids = neighborhood_ids.uniq
      return [] if ids.empty?

      current = HouseholdVersion.joins(household: :micro_area).where("household_versions.version = households.version")
                                .where(neighborhood_id: ids, households: { status: "active" })
      registered = current.group(:neighborhood_id).count
      to_visit = current.where(micro_areas: { active: true }).group(:neighborhood_id).count
      visits = visits_by_neighborhood(cycle, ids)
      ids.map do |id|
        stats = visits.fetch(id) { Hash.new(0) }
        visited = stats[:visited]
        { neighborhood_id: id, to_visit: to_visit.fetch(id, 0), visited: visited, worked: stats["worked"], closed: stats["closed"],
          refused: stats["refused"], vacant: stats["vacant"], recovered: stats[:recovered],
          pending_percent: visited.zero? ? nil : ((stats["closed"] + stats["refused"]) * 100.0 / visited).round(1),
          registered_households: registered.fetch(id, 0) }
      end
    end

    # { neighborhood_id => { visited:, recovered:, "<situação>" => n } } pela
    # última inspeção válida de cada domicílio no período, agregada no banco:
    # um DISTINCT ON por domicílio (a última pela hora da visita, created_at e
    # id), com bool_or(recovered) sobre o período inteiro do domicílio, e
    # depois GROUP BY (bairro, situação) — poucas linhas por bairro, nenhuma
    # por inspeção.
    def visits_by_neighborhood(cycle, ids)
      period = cycle.starts_on.beginning_of_day...(cycle.ends_on + 1).beginning_of_day
      last = VectorInspection.valid_inspections
                             .joins("JOIN households cycle_households ON cycle_households.id = vector_inspections.household_id")
                             .joins("JOIN household_versions cycle_versions ON cycle_versions.household_id = cycle_households.id " \
                                    "AND cycle_versions.version = cycle_households.version")
                             .where(home_visits: { occurred_at: period })
                             .where("cycle_versions.neighborhood_id IN (?)", ids)
                             .select("DISTINCT ON (vector_inspections.household_id) cycle_versions.neighborhood_id AS neighborhood_id",
                                     "vector_inspections.situation AS situation",
                                     "bool_or(vector_inspections.recovered) OVER (PARTITION BY vector_inspections.household_id) AS recovered")
                             .reorder(Arel.sql("vector_inspections.household_id, home_visits.occurred_at DESC, " \
                                               "vector_inspections.created_at DESC, vector_inspections.id DESC"))
      rows = VectorInspection.unscoped.from(last, :last_inspections)
                             .group("last_inspections.neighborhood_id", "last_inspections.situation")
                             .pluck("last_inspections.neighborhood_id", "last_inspections.situation", Arel.sql("count(*)"),
                                    Arel.sql("count(*) FILTER (WHERE last_inspections.recovered)"))
      rows.each_with_object({}) do |(neighborhood_id, situation, count, recovered), map|
        stats = (map[neighborhood_id] ||= Hash.new(0))
        stats[:visited] += count
        stats[situation] += count
        stats[:recovered] += recovered
      end
    end
  end
end
