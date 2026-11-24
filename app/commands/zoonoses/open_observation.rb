# Abertura da observação do animal agressor (módulo 35b, ADR 0054; contrato
# §5, Q16), chamada pelo Zoonoses::OpenObservationJob depois do gate, da
# doença e do estado da notificação. Lê o bloco do animal da ficha (o `form`
# cifrado do 25, nunca copiado além da espécie e da data):
#   - `animal_observable` "true", com `animal_species` dog ou cat, e
#     `exposure_on` "AAAA-MM-DD" → abre; senão nada (Result.ok(observation: nil));
#   - já há observação da notificação → nada: a ficha editada depois
#     (exposure_on corrigido, observável desmarcado) não abre outra nem muda
#     ends_on; a aberta segue (Review Focus 3). Na corrida, o único
#     idx_bite_observations_notification decide, num savepoint
#     (RecordNotUnique desse índice → nada);
#   - ends_on = exposure_on + observation_days (Zoonoses::Parameters); place
#     home (Q16: vira shelter na entrada observation do canil).
#
# `bite_observation.opened` só com o id.
module Zoonoses
  module OpenObservation
    EVENT = "bite_observation.opened".freeze
    UNIQUE_INDEX = "idx_bite_observations_notification".freeze
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    SPECIES = %w[dog cat].freeze

    module_function

    # -> Result.ok(observation: BiteObservation | nil)
    def call(notification:, parameters:)
      block = observable(notification.form)
      return Result.ok(observation: nil) unless block
      return Result.ok(observation: nil) if BiteObservation.exists?(disease_notification_id: notification.id)

      days = Integer(parameters.fetch("observation_days"))
      observation = BiteObservation.transaction(requires_new: true) do
        BiteObservation.create!(disease_notification_id: notification.id, species: block[:species], exposure_on: block[:exposure_on],
                                ends_on: block[:exposure_on] + days, place: "home", state: "open")
      end
      DomainEvents.publish(
        EVENT,
        bite_observation_id: observation.id
      )
      Result.ok(observation: observation)
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(UNIQUE_INDEX)

      Result.ok(observation: nil)
    end

    # O bloco do animal observável. -> { species:, exposure_on: } | nil
    def observable(form)
      return nil unless form.is_a?(Hash) && form["animal_observable"] == "true"
      return nil unless SPECIES.include?(form["animal_species"])

      exposure_on = date(form["exposure_on"])
      exposure_on && { species: form["animal_species"], exposure_on: exposure_on }
    end

    def date(value)
      value.is_a?(String) && value.match?(DATE) ? Date.strptime(value, "%Y-%m-%d") : nil
    rescue Date::Error
      nil
    end

    private_class_method :observable, :date
  end
end
