# Substitui o conjunto de unidades que cobrem o bairro (ADR 0023; spec §4.2).
# Trava o bairro (FOR UPDATE): duas edições simultâneas não calculam
# adicionados/removidos sobre o mesmo estado velho. Toda unidade do conjunto
# novo precisa existir e estar ativa. Reasons: :inactive_neighborhood,
# :inactive_unit.
module Territory
  class ReplaceCoverage
    def self.call(neighborhood:, health_unit_ids:, by:)
      ids = Array(health_unit_ids).map { _1.to_s.downcase }.uniq
      result = nil
      ApplicationRecord.transaction do
        locked = Neighborhood.lock("FOR UPDATE").find(neighborhood.id)
        result = replace(locked, ids, by)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def self.replace(neighborhood, ids, by)
      return Result.fail(:inactive_neighborhood) unless neighborhood.active?
      return Result.fail(:inactive_unit) unless HealthUnit.where(id: ids, active: true).count == ids.size

      current = neighborhood.coverages.pluck(:health_unit_id)
      added = (ids - current).sort
      removed = (current - ids).sort
      neighborhood.coverages.where(health_unit_id: removed).delete_all if removed.any?
      added.each { |id| neighborhood.coverages.create!(health_unit_id: id) }
      if added.any? || removed.any?
        DomainEvents.publish("neighborhood.coverage_changed", neighborhood_id: neighborhood.id,
                                                              added_unit_ids: added, removed_unit_ids: removed,
                                                              by_user_id: by&.id)
      end
      Result.ok(neighborhood: neighborhood, added: added, removed: removed)
    end
    private_class_method :replace
  end
end
