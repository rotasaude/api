# Atribui o quarteirão em lote (módulo 35a, ADR 0054; contrato §2; Q2): só a
# coordenação (quem chama confere). `household_ids` de 1 a ASSIGN_BATCH ids
# distintos (senão 422 invalid_request, path household_ids ou
# household_ids[i]); quarteirão ativo (senão 422 invalid_request, path
# city_block_id). Tudo ou nada, o primeiro erro na ordem do corpo: domicílio
# que não existe → invalid_request; sem neighborhood_id na versão atual do 24a
# → household_without_neighborhood; de outro bairro →
# block_not_in_household_neighborhood (path household_ids[i]). O quarteirão
# fica FOR SHARE (a desativação espera) e os perfis FOR UPDATE (criados se
# faltarem), com version + 1, updated_by_user_id e um
# household_vector_profile.changed por domicílio (só ids). Nunca escreve no
# 24a. Devolve ok(assigned: Integer).
module VectorControl
  module AssignBlock
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def call(household_ids:, city_block_id:, by:)
      ids = household_ids
      return invalid("household_ids") unless ids.is_a?(Array) && ids.size.between?(1, Catalog::ASSIGN_BATCH)

      bad = ids.index { |id| !(id.is_a?(String) && id.match?(UUID)) }
      return invalid("household_ids[#{bad}]") if bad

      ids = ids.map(&:downcase)
      bad = ids.each_index.find { |i| ids.index(ids[i]) != i }
      return invalid("household_ids[#{bad}]") if bad
      return invalid("city_block_id") unless city_block_id.is_a?(String) && city_block_id.match?(UUID)

      HouseholdVectorProfile.transaction(requires_new: true) do
        block = CityBlock.active_blocks.lock("FOR SHARE").find_by(id: city_block_id)
        next invalid("city_block_id") unless block

        refusal = refusal(ids, block)
        next refusal if refusal

        profiles, created = SaveProfile.lock_profiles!(ids, by: by)
        ids.each do |id|
          SaveProfile.write!(profiles.fetch(id), { city_block_id: block.id }, by, created: created.include?(id))
        end
        Result.ok(assigned: ids.size)
      end
    end

    # O primeiro domicílio recusado, na ordem do corpo (nil = todos aceitos).
    def refusal(ids, block)
      existing = Household.where(id: ids).pluck(:id).to_set
      neighborhoods = SaveProfile.current_neighborhood_ids(ids)
      ids.each_with_index do |id, i|
        path = { path: "household_ids[#{i}]" }
        return Result.fail(:invalid_request, details: path) unless existing.include?(id)
        return Result.fail(:household_without_neighborhood, details: path) if neighborhoods[id].nil?
        return Result.fail(:block_not_in_household_neighborhood, details: path) if neighborhoods[id] != block.neighborhood_id
      end
      nil
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
  end
end
