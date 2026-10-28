# Lista municipal do que o enfermeiro (CBO 2235*) pode pedir à regulação
# (contrato §6). Configuração: o item sai e volta.
module CareRegulation
  module NurseItems
    module_function

    # -> [{ target_type:, target_code:, name: }], por tipo e nome.
    def list(on: Time.zone.today)
      pairs = NurseRequestableItem.pluck(:target_type, :target_code)
      names = Targets.names_for(pairs, on: on)
      pairs.map do |type, code|
        { target_type: type, target_code: code, name: names.fetch([ type, code ]) }
      end.sort_by { |item| [ item[:target_type], item[:name].to_s.downcase, item[:target_code] ] }
    end

    # -> Result.ok(item:, target:) | fail(:invalid_target, details: { path:[, hint:] }) |
    # fail(:duplicate_item).
    def add(target_type:, target_code:, by:)
      resolved = Targets.resolve(type: target_type, code: target_code)
      return resolved if resolved.failure?

      target = resolved.payload.fetch(:target)
      NurseRequestableItem.transaction do
        next Result.fail(:duplicate_item) if NurseRequestableItem.exists?(target_type: target.type, target_code: target.code)

        item = NurseRequestableItem.create!(target_type: target.type, target_code: target.code, created_by_user: by)
        DomainEvents.publish("care_regulation.settings_changed", user_id: by.id)
        Result.ok(item: item, target: target)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:duplicate_item)
    end

    # -> Result.ok | fail(:not_found). Sai mesmo que o alvo já não seja regulável.
    def remove(target_type:, target_code:, by:)
      item = target_type.is_a?(String) && target_code.is_a?(String) &&
             NurseRequestableItem.find_by(target_type: target_type, target_code: target_code)
      return Result.fail(:not_found) unless item

      NurseRequestableItem.transaction do
        item.destroy!
        DomainEvents.publish("care_regulation.settings_changed", user_id: by.id)
      end
      Result.ok
    end
  end
end
