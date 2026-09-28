# Desativa ou reativa um bairro (ADR 0023). Desativar não apaga cobertura nem
# o bairro de quem já o declarou: só tira o bairro das escolhas novas.
module Territory
  class SetNeighborhoodActive
    def self.call(neighborhood:, active:, by:)
      return Result.ok(neighborhood: neighborhood) if neighborhood.active == active

      ApplicationRecord.transaction do
        neighborhood.update!(active: active)
        DomainEvents.publish(active ? "neighborhood.activated" : "neighborhood.deactivated",
                             neighborhood_id: neighborhood.id, by_user_id: by&.id)
      end
      Result.ok(neighborhood: neighborhood)
    end
  end
end
