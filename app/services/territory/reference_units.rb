# Unidade de referência (ADR 0023; spec 2026-09-28 §4.2): as unidades ATIVAS
# que cobrem o bairro, por nome. Calculada na hora, nunca gravada; informa e
# sugere, nunca restringe. Fonte única do cidadão (GET /citizen/triages/:id)
# e do atendimento (reference_unit_ids na fila da unidade). Não vai para o
# relatório público (/r/:token): decisão de 2026-09-28.
module Territory
  module ReferenceUnits
    module_function

    def for(neighborhood_id)
      return [] if neighborhood_id.blank?

      HealthUnit.where(active: true)
                .where(id: NeighborhoodCoverage.where(neighborhood_id: neighborhood_id).select(:health_unit_id))
                .order(:name).to_a
    end

    # Várias de uma vez (fila da unidade, sem N+1).
    def ids_by_neighborhood(neighborhood_ids)
      ids = neighborhood_ids.compact.uniq
      return {} if ids.empty?

      NeighborhoodCoverage.joins(:health_unit)
                          .where(neighborhood_id: ids, health_units: { active: true })
                          .order("health_units.name")
                          .pluck(:neighborhood_id, :health_unit_id)
                          .group_by(&:first)
                          .transform_values { |pairs| pairs.map(&:last) }
    end

    def as_json_list(units)
      units.map do |u|
        {
          id: u.id, name: u.name, kind: u.kind,
          address: Scheduling::UnitAddress.call(u)
        }
      end
    end
  end
end
