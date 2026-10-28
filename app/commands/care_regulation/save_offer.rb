# Cadastra e edita ofertas mensais por prestador e alvo (contrato §6; G1, G5).
# `month` é "YYYY-MM", igual ou depois do mês corrente no fuso da cidade (mês
# passado não se cadastra; futuro pode). No PATCH só a quantidade muda
# (reenviar os outros campos iguais vale; diferentes são invalid_request). A
# edição trava a oferta (FOR UPDATE), conta o usado (Quota) e recusa quantity
# abaixo dele (422 com `used` no corpo). Prestador inativo não recebe oferta
# nova (a edição de quantidade de oferta existente segue valendo). Evento `care_offer.changed` só com ids, e só quando algo mudou.
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

      target = resolved.payload.fetch(:target)
      CareOffer.transaction(requires_new: true) do
        next Result.fail(:duplicate_offer) if CareOffer.exists?(care_provider_id: provider.id, target_type: target.type, target_code: target.code, month: month)

        offer = CareOffer.create!(care_provider: provider, target_type: target.type, target_code: target.code, month: month,
                                  quantity: attrs["quantity"], updated_by_user: by)
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
      return refuse("quantity") unless valid_quantity?(attrs["quantity"])

      CareOffer.transaction(requires_new: true) do
        locked = CareOffer.lock.find(offer.id)
        used = Quota.used([ locked.id ]).fetch(locked.id)
        next Result.fail(:quantity_below_used, details: { used: used }) if attrs["quantity"] < used
        next Result.ok(offer: locked) if attrs["quantity"] == locked.quantity

        locked.update!(quantity: attrs["quantity"], updated_by_user: by)
        publish(locked, by)
        Result.ok(offer: locked)
      end
    end

    def valid_quantity?(value) = value.is_a?(Integer) && Catalog::QUANTITY.cover?(value)
    def publish(offer, by) = DomainEvents.publish("care_offer.changed", care_offer_id: offer.id, user_id: by.id)
    def refuse(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :create, :update, :valid_quantity?, :publish, :refuse
  end
end
