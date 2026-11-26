# Cadastra e edita ofertas mensais por prestador e alvo (contrato §6; G1, G5).
# `month` é "YYYY-MM", igual ou depois do mês corrente no fuso da cidade (mês
# passado não se cadastra; futuro pode). No PATCH só a quantidade muda
# (reenviar os outros campos iguais vale; diferentes são invalid_request). A
# edição trava a oferta (FOR UPDATE), conta o usado (Quota) e recusa quantity
# abaixo dele (422 com `used` no corpo). Prestador inativo não recebe oferta
# nova (a edição de quantidade de oferta existente segue valendo). Módulo 26c
# (Q12): `performer_cbo` (6 dígitos ou nulo; `invalid_cbo`). No POST, ausente
# = herda o da oferta do mês anterior (mesmo prestador, alvo); no PATCH vale
# sozinho (sem `quantity`) e o PATCH vazio é 422 path quantity. Evento `care_offer.changed` só com ids, e só quando algo mudou.
module CareRegulation
  module SaveOffer
    IMMUTABLE = %w[provider_id target_type target_code month].freeze

    module_function

    # attrs: corpo JSON (chaves texto). -> Result.ok(offer:) |
    # fail(:invalid_request, details: { path: }) | fail(:invalid_target, …) |
    # fail(:invalid_month) | fail(:duplicate_offer) | fail(:quantity_below_used).
    def call(attrs:, by:, offer: nil, today: Time.zone.today)
      attrs = attrs.to_h.stringify_keys
      offer ? update(offer, attrs, by) : create(attrs, by, today)
    end

    def create(attrs, by, today)
      provider = attrs["provider_id"].is_a?(String) ? CareProvider.find_by(id: attrs["provider_id"]) : nil
      return refuse("provider_id") unless provider&.active

      resolved = Targets.resolve(type: attrs["target_type"], code: attrs["target_code"], on: today)
      return resolved if resolved.failure?

      month = Catalog.parse_month(attrs["month"])
      return refuse("month") unless month
      return Result.fail(:invalid_month) if month < today.beginning_of_month
      return refuse("quantity") unless valid_quantity?(attrs["quantity"])
      return refuse_cbo unless valid_cbo?(attrs["performer_cbo"])

      target = resolved.payload.fetch(:target)
      CareOffer.transaction(requires_new: true) do
        next Result.fail(:duplicate_offer) if CareOffer.exists?(care_provider_id: provider.id, target_type: target.type, target_code: target.code, month: month)

        cbo = attrs.key?("performer_cbo") ? attrs["performer_cbo"] : inherited_cbo(provider, target, month)
        offer = CareOffer.create!(care_provider: provider, target_type: target.type, target_code: target.code, month: month,
                                  quantity: attrs["quantity"], performer_cbo: cbo, updated_by_user: by)
        publish(offer, by)
        Result.ok(offer: offer)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:duplicate_offer)
    end

    def update(offer, attrs, by)
      current = { "provider_id" => offer.care_provider_id, "target_type" => offer.target_type, "target_code" => offer.target_code,
                  "month" => offer.month_label }
      IMMUTABLE.each { |key| return refuse(key) if attrs.key?(key) && attrs[key] != current[key] }
      change_quantity = attrs.key?("quantity") || !attrs.key?("performer_cbo")
      return refuse("quantity") if change_quantity && !valid_quantity?(attrs["quantity"])
      return refuse_cbo if attrs.key?("performer_cbo") && !valid_cbo?(attrs["performer_cbo"])

      CareOffer.transaction(requires_new: true) do
        locked = CareOffer.lock.find(offer.id)
        if change_quantity
          used = Quota.used([ locked.id ]).fetch(locked.id)
          next Result.fail(:quantity_below_used, details: { used: used }) if attrs["quantity"] < used

          locked.quantity = attrs["quantity"]
        end
        locked.performer_cbo = attrs["performer_cbo"] if attrs.key?("performer_cbo")
        next Result.ok(offer: locked) unless locked.changed?

        locked.updated_by_user = by
        locked.save!
        publish(locked, by)
        Result.ok(offer: locked)
      end
    end

    def valid_cbo?(value) = value.nil? || (value.is_a?(String) && value.match?(Catalog::SPECIALTY_CODE))

    # O CBO da oferta do mês anterior do mesmo prestador e alvo (nulo se não há).
    def inherited_cbo(provider, target, month)
      CareOffer.find_by(care_provider_id: provider.id, target_type: target.type, target_code: target.code,
                        month: month - 1.month)&.performer_cbo
    end

    def valid_quantity?(value) = value.is_a?(Integer) && Catalog::QUANTITY.cover?(value)
    def publish(offer, by) = DomainEvents.publish("care_offer.changed", care_offer_id: offer.id, user_id: by.id)
    def refuse(path) = Result.fail(:invalid_request, details: { path: path })
    def refuse_cbo = Result.fail(:invalid_cbo, details: { path: "performer_cbo" })

    private_class_method :create, :update, :valid_cbo?, :inherited_cbo, :valid_quantity?, :publish, :refuse, :refuse_cbo
  end
end
