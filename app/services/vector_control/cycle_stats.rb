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
# Consultas constantes; só contagens, nunca imóvel nem pessoa. A Task 13 (o
# relatório `situations`) reusa.
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
    # última inspeção válida de cada domicílio no período.
    def visits_by_neighborhood(cycle, ids)
      period = cycle.starts_on.beginning_of_day...(cycle.ends_on + 1).beginning_of_day
      rows = VectorInspection.valid_inspections
                             .joins("JOIN households cycle_households ON cycle_households.id = vector_inspections.household_id")
                             .joins("JOIN household_versions cycle_versions ON cycle_versions.household_id = cycle_households.id " \
                                    "AND cycle_versions.version = cycle_households.version")
                             .where(home_visits: { occurred_at: period })
                             .where("cycle_versions.neighborhood_id IN (?)", ids)
                             .pluck("cycle_versions.neighborhood_id", "vector_inspections.household_id", "vector_inspections.situation",
                                    "vector_inspections.recovered", "home_visits.occurred_at", "vector_inspections.created_at",
                                    "vector_inspections.id")
      rows.group_by { |row| row[1] }.each_with_object({}) do |(_household_id, inspections), map|
        last = inspections.max_by { |row| row[4..6] }
        stats = (map[last[0]] ||= Hash.new(0))
        stats[:visited] += 1
        stats[last[2]] += 1
        stats[:recovered] += 1 if inspections.any? { |row| row[3] }
      end
    end
  end
end
