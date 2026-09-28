# Cria um bairro (ADR 0023; spec 2026-09-28-module-11-territory §4.2). O
# municipal_admin cria com source manual e sem seed_key; a semente
# (Territory::Seed), com seed, a chave estável do YAML e sem autor.
# Reasons: :blank_name (vazio ou acima de 120), :name_taken.
module Territory
  class CreateNeighborhood
    def self.call(name:, by:, source: "manual", seed_key: nil)
      neighborhood = Neighborhood.new(name: name, source: source, seed_key: seed_key)
      return Result.fail(:blank_name) if neighborhood.name.blank? || neighborhood.name.length > Neighborhood::NAME_MAX
      return Result.fail(:name_taken) if Neighborhood.named(neighborhood.name).exists?

      ApplicationRecord.transaction do
        neighborhood.save!
        DomainEvents.publish("neighborhood.created", neighborhood_id: neighborhood.id, source: neighborhood.source,
                                                     by_user_id: by&.id)
      end
      Result.ok(neighborhood: neighborhood)
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:name_taken)
    end
  end
end
