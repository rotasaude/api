# Edita o perfil do imóvel (módulo 35a, ADR 0054; contrato §2; Q2): só a
# coordenação (quem chama confere). Corpo `{ city_block_id?, risk_class? }`;
# null limpa. Quarteirão novo: ativo (senão 422 invalid_request, path
# city_block_id) e do bairro da versão atual do 24a (sem bairro → 422
# household_without_neighborhood; outro → 422
# block_not_in_household_neighborhood; path city_block_id). Manter o mesmo
# quarteirão não confere o bairro (o perfil fica, §2). Risco grava
# risk_assessed_on = hoje. Perfil FOR UPDATE (criado se faltar), version + 1,
# updated_by_user_id e household_vector_profile.changed (só ids). Nunca
# escreve no 24a. Devolve ok(profile:).
module VectorControl
  module SaveProfile
    KEYS = %w[city_block_id risk_class].freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    UNIQUE = :idx_household_vector_profiles_household

    module_function

    def call(household:, params:, by:)
      params = params.to_h.stringify_keys
      unknown = (params.keys - KEYS).first
      return invalid(unknown) if unknown
      return invalid(nil) if params.empty?

      risk = params["risk_class"]
      return invalid("risk_class") if params.key?("risk_class") && !risk.nil? && !Catalog::RISK_CLASSES.include?(risk)

      block_id = params["city_block_id"]
      return invalid("city_block_id") if params.key?("city_block_id") && !block_id.nil? && !(block_id.is_a?(String) && block_id.match?(UUID))

      result = nil
      HouseholdVectorProfile.transaction(requires_new: true) do
        profiles, created = lock_profiles!([ household.id ], by: by)
        profile = profiles.fetch(household.id)
        attrs = {}
        if params.key?("city_block_id") && block_id != profile.city_block_id
          # Recusa desfaz o perfil criado acima: nada gravado.
          result = block_id && block_refusal(household, block_id)
          raise ActiveRecord::Rollback if result

          attrs[:city_block_id] = block_id
        end
        if params.key?("risk_class")
          attrs[:risk_class] = risk
          attrs[:risk_assessed_on] = risk && Time.zone.today
        end
        write!(profile, attrs, by, created: created.include?(household.id))
        result = Result.ok(profile: profile)
      end
      result
    end

    # [{ household_id => perfil travado FOR UPDATE }, ids criados agora]. Os
    # que faltam nascem na versão 1, sem quarteirão nem risco; a inserção sem
    # conflito espera a de outra transação no mesmo domicílio, e a trava, em
    # ordem de id, decide a corrida. Também serve ao AssignBlock.
    def lock_profiles!(household_ids, by:)
      now = Time.current
      # Inserção em ordem de id: dois lotes com os mesmos domicílios em ordens
      # diferentes não se travam no índice único.
      rows = household_ids.sort.map { |id| { household_id: id, updated_by_user_id: by.id, created_at: now, updated_at: now } }
      created = HouseholdVectorProfile.insert_all(rows, unique_by: UNIQUE, returning: [ :household_id ]).rows.flatten.to_set
      [ HouseholdVectorProfile.where(household_id: household_ids).order(:id).lock.index_by(&:household_id), created ]
    end

    # Grava `attrs` com o autor e version + 1 (o perfil criado nesta
    # transação fica na versão 1). Um evento por domicílio.
    def write!(profile, attrs, by, created:)
      profile.update!(attrs.merge(version: created ? profile.version : profile.version + 1, updated_by_user_id: by.id))
      DomainEvents.publish("household_vector_profile.changed", household_id: profile.household_id, user_id: by.id)
    end

    def block_refusal(household, block_id)
      block = CityBlock.active_blocks.lock("FOR SHARE").find_by(id: block_id)
      return invalid("city_block_id") unless block

      neighborhood_id = current_neighborhood_ids([ household.id ])[household.id]
      return Result.fail(:household_without_neighborhood, details: { path: "city_block_id" }) if neighborhood_id.nil?
      return Result.fail(:block_not_in_household_neighborhood, details: { path: "city_block_id" }) if neighborhood_id != block.neighborhood_id

      nil
    end

    # { household_id => neighborhood_id da versão atual do 24a }.
    def current_neighborhood_ids(household_ids)
      HouseholdVersion.joins(:household).where(household_id: household_ids).where("household_versions.version = households.version")
                      .pluck(:household_id, :neighborhood_id).to_h
    end

    def invalid(path) = Result.fail(:invalid_request, details: path ? { path: path } : {})
  end
end
