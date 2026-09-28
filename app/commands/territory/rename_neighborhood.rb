# Renomeia um bairro (ADR 0023). Só mudar a caixa é aceito; o evento não leva
# o nome (só ids). Reasons: :blank_name, :name_taken.
module Territory
  class RenameNeighborhood
    def self.call(neighborhood:, name:, by:)
      new_name = name.to_s.squish
      return Result.fail(:blank_name) if new_name.empty? || new_name.length > Neighborhood::NAME_MAX
      return Result.ok(neighborhood: neighborhood) if new_name == neighborhood.name
      return Result.fail(:name_taken) if Neighborhood.named(new_name).where.not(id: neighborhood.id).exists?

      ApplicationRecord.transaction do
        neighborhood.update!(name: new_name)
        DomainEvents.publish("neighborhood.renamed", neighborhood_id: neighborhood.id, by_user_id: by&.id)
      end
      Result.ok(neighborhood: neighborhood)
    rescue ActiveRecord::RecordNotUnique
      neighborhood.restore_attributes
      Result.fail(:name_taken)
    end
  end
end
