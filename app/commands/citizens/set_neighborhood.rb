# Bairro declarado pelo cidadão (ADR 0023; spec 2026-09-28 §4.2). nil (ou "")
# = "prefiro não informar", ou apagar o que tinha. Recusa bairro inativo ou
# inexistente. Trocar o bairro não muda triagem antiga: a cópia de cada uma é
# imutável (trigger triages_neighborhood_immutable). O evento só sai quando
# muda, e leva só ids. Reasons: :invalid_neighborhood.
module Citizens
  class SetNeighborhood
    def self.call(citizen:, neighborhood_id:)
      target = neighborhood_id.to_s.downcase.presence
      return Result.fail(:invalid_neighborhood) if target && !Neighborhood.active_neighborhoods.exists?(id: target)

      ApplicationRecord.transaction do
        citizen.lock!
        from = citizen.neighborhood_id
        next if from == target

        citizen.update!(neighborhood_id: target)
        DomainEvents.publish("citizen.neighborhood_changed", citizen_id: citizen.id, from_id: from, to_id: target)
      end
      Result.ok(citizen: citizen)
    end
  end
end
