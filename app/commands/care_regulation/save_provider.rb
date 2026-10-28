# Cadastra e edita prestadores da regulação (contrato §6; G5, G7). Prestador
# `own` é a unidade da rede: exige unidade ativa, herda o CNES dela e não muda
# de tipo nem de unidade; externo (contracted, consortium, ppi) exige CNES.
# CNES e unidade são únicos entre prestadores. Nome de 3 a 120 caracteres,
# recusado, nunca cortado. Evento `care_provider.changed` só com ids, e só
# quando algo mudou.
module CareRegulation
  module SaveProvider
    module_function

    # attrs: corpo JSON (chaves texto). -> Result.ok(provider:) |
    # fail(:invalid_request, details: { path: }) | fail(:cnes_taken) |
    # fail(:unit_taken).
    def call(attrs:, by:, provider: nil)
      attrs = attrs.to_h.stringify_keys
      provider ? update(provider, attrs, by) : create(attrs, by)
    rescue ActiveRecord::RecordNotUnique => e
      Result.fail(e.message.include?("idx_care_providers_unit") ? :unit_taken : :cnes_taken)
    end

    def create(attrs, by)
      name = valid_name(attrs["name"])
      return refuse("name") unless name

      kind = attrs["kind"]
      return refuse("kind") unless Catalog::PROVIDER_KINDS.include?(kind)

      active = attrs.fetch("active", true)
      return refuse("active") unless [ true, false ].include?(active)

      CareProvider.transaction(requires_new: true) do
        unit_id, cnes = kind == "own" ? own_unit_and_cnes(attrs) : external_cnes(attrs)
        next unit_id if unit_id.is_a?(Result)

        taken = taken_reason(unit_id: unit_id, cnes: cnes)
        next Result.fail(taken) if taken

        provider = CareProvider.create!(name: name, kind: kind, health_unit_id: unit_id, cnes: cnes, active: active, updated_by_user: by)
        publish(provider, by)
        Result.ok(provider: provider)
      end
    end

    def update(provider, attrs, by)
      return refuse("kind") if attrs.key?("kind") && attrs["kind"] != provider.kind
      return refuse("health_unit_id") if attrs.key?("health_unit_id") && attrs["health_unit_id"] != provider.health_unit_id

      CareProvider.transaction(requires_new: true) do
        provider.lock!
        if attrs.key?("name")
          name = valid_name(attrs["name"])
          next refuse("name") unless name

          provider.name = name
        end
        if attrs.key?("active")
          next refuse("active") unless [ true, false ].include?(attrs["active"])

          provider.active = attrs["active"]
        end
        if attrs.key?("cnes")
          next refuse("cnes") unless provider.kind == "own" ? attrs["cnes"] == provider.cnes : valid_cnes?(attrs["cnes"])

          provider.cnes = attrs["cnes"]
        end
        next Result.ok(provider: provider) unless provider.changed?

        taken = taken_reason(unit_id: nil, cnes: provider.cnes, except: provider.id)
        next Result.fail(taken) if taken

        provider.updated_by_user = by
        provider.save!
        publish(provider, by)
        Result.ok(provider: provider)
      end
    end

    # -> [unit_id, cnes] | [Result, nil]
    def own_unit_and_cnes(attrs)
      id = attrs["health_unit_id"]
      unit = id.is_a?(String) ? HealthUnit.lock_active!(id) : nil
      return [ refuse("health_unit_id"), nil ] unless unit
      return [ refuse("cnes"), nil ] if attrs.key?("cnes") && attrs["cnes"] != unit.cnes

      [ unit.id, unit.cnes ]
    rescue HealthUnit::Inactive
      [ refuse("health_unit_id"), nil ]
    end

    def external_cnes(attrs)
      return [ refuse("health_unit_id"), nil ] unless attrs["health_unit_id"].nil?
      return [ refuse("cnes"), nil ] unless valid_cnes?(attrs["cnes"])

      [ nil, attrs["cnes"] ]
    end

    def valid_name(value)
      return nil unless value.is_a?(String)

      name = value.strip
      Catalog::PROVIDER_NAME.cover?(name.length) ? name : nil
    end

    def valid_cnes?(value) = value.is_a?(String) && value.match?(Catalog::CNES)

    def taken_reason(unit_id:, cnes:, except: nil)
      scope = except ? CareProvider.where.not(id: except) : CareProvider
      return :unit_taken if unit_id && scope.exists?(health_unit_id: unit_id)

      :cnes_taken if cnes && scope.exists?(cnes: cnes)
    end

    def publish(provider, by) = DomainEvents.publish("care_provider.changed", care_provider_id: provider.id, user_id: by.id)
    def refuse(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :create, :update, :own_unit_and_cnes, :external_cnes, :valid_name, :valid_cnes?, :taken_reason, :publish, :refuse
  end
end
