# Eutanásia (módulo 35b, ADR 0054; contrato §1, §7 e o invariante; decisão
# 20; Q30, Q31; Review Focus 4). A rota pede step-up (o controller). Corpo:
# `animal_id`, `performed_on` ("AAAA-MM-DD", até hoje → senão
# date_out_of_range), `reason` (Catalog::EUTHANASIA_REASONS), `reason_note`
# (obrigatória, 10–1000 depois do strip: recusada, nunca cortada; cifrada),
# `legal_basis` (lista não vazia, sem repetição, ⊂ Catalog::LEGAL_BASES),
# `shelter_stay_id` e `bite_observation_id` (opcionais, do mesmo animal; a
# observação, ABERTA: a fechada já teve desfecho). Toda
# recusa de campo é invalid_request com o path.
#
#   - Quem: só Access.veterinarian? (senão 403 veterinarian_required); o
#     professional_id é o do usuário, congelado (o registro é imutável:
#     trigger rota_reencryption_only e nenhuma rota de edição).
#   - O animal FOR UPDATE (a primeira trava das escritas do canil): já há
#     eutanásia → 409 already_euthanized (também na corrida, pelo índice único
#     idx_euthanasias_animal); senão, fora de active ou missing → 409
#     animal_not_active (Q31).
#   - Na mesma transação (Zoonoses::AnimalDeath): o animal a deceased com
#     status_on = performed_on e a coleira ativa sai com death. A estada
#     aberta continua aberta: fecha só pela saída euthanasia
#     (Zoonoses::ExitShelter). A observação aberta segue até o desfecho.
#
# `euthanasia.recorded` só com o id. A nota nunca em Result.details.
module Zoonoses
  module RecordEuthanasia
    EVENT = "euthanasia.recorded".freeze
    KEYS = %w[animal_id performed_on reason reason_note legal_basis shelter_stay_id bite_observation_id].freeze
    REQUIRED = %w[animal_id performed_on reason reason_note legal_basis].freeze
    UNIQUE_INDEX = "idx_euthanasias_animal".freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    KEY_PATH_MAX = 64

    module_function

    # -> Result.ok(euthanasia:) | fail(:invalid_request | :date_out_of_range, details: { path: }) |
    #    fail(:veterinarian_required | :already_euthanized | :animal_not_active)
    def call(params:, by:, today: Time.zone.today)
      return Result.fail(:veterinarian_required) unless Access.veterinarian?(by)

      params = params.to_h.stringify_keys
      attrs = parse(params, today)
      return attrs if attrs.is_a?(Result)

      Euthanasia.transaction(requires_new: true) { record(attrs, by) }
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(UNIQUE_INDEX)

      Result.fail(:already_euthanized)
    end

    def record(attrs, by)
      animal = Animal.lock.find_by(id: attrs[:animal_id])
      return invalid("animal_id") unless animal
      return Result.fail(:already_euthanized) if Euthanasia.exists?(animal_id: animal.id)
      return Result.fail(:animal_not_active) unless SaveAnimal::TRANSITIONS.key?(animal.status)
      if attrs[:shelter_stay_id] && !ShelterStay.exists?(id: attrs[:shelter_stay_id], animal_id: animal.id)
        return invalid("shelter_stay_id")
      end
      if attrs[:bite_observation_id] && !BiteObservation.open_observations.exists?(id: attrs[:bite_observation_id], animal_id: animal.id)
        return invalid("bite_observation_id")
      end

      euthanasia = Euthanasia.create!(attrs.merge(animal: animal, professional_id: by.professional.id))
      AnimalDeath.apply!(animal: animal, on: euthanasia.performed_on)
      DomainEvents.publish(EVENT, euthanasia_id: euthanasia.id)
      Result.ok(euthanasia: euthanasia)
    end

    # Forma do corpo. -> { atributo => valor } | Result de recusa (só a primeira).
    def parse(params, today)
      unknown = params.keys.find { |key| !KEYS.include?(key) }
      return invalid(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      missing = REQUIRED.find { |key| !params.key?(key) }
      return invalid(missing) if missing
      return invalid("animal_id") unless uuid?(params["animal_id"])
      return invalid("reason") unless Catalog::EUTHANASIA_REASONS.include?(params["reason"])

      note = params["reason_note"].is_a?(String) ? params["reason_note"].strip : nil
      return invalid("reason_note") unless note && Catalog::EUTHANASIA_NOTE.cover?(note.length)

      bases = params["legal_basis"]
      valid_bases = bases.is_a?(Array) && bases.any? && bases.uniq.size == bases.size && bases.all? { Catalog::LEGAL_BASES.include?(_1) }
      return invalid("legal_basis") unless valid_bases

      %w[shelter_stay_id bite_observation_id].each do |key|
        return invalid(key) if params.key?(key) && !uuid?(params[key])
      end
      performed_on = date(params["performed_on"])
      return invalid("performed_on") unless performed_on
      return Result.fail(:date_out_of_range, details: { path: "performed_on" }) if performed_on > today

      { animal_id: params["animal_id"].downcase, performed_on: performed_on, reason: params["reason"], reason_note: note,
        legal_basis: bases, shelter_stay_id: params["shelter_stay_id"]&.downcase,
        bite_observation_id: params["bite_observation_id"]&.downcase }
    end

    def date(value)
      value.is_a?(String) && value.match?(DATE) ? Date.strptime(value, "%Y-%m-%d") : nil
    rescue Date::Error
      nil
    end

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    def invalid(path) = Result.fail(:invalid_request, details: { path: path })

    private_class_method :record, :parse, :date, :uuid?, :invalid
  end
end
