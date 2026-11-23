# A morte do animal no centro de zoonoses (módulo 35b, ADR 0054; contrato §7,
# Q31; Review Focus 4), comum à eutanásia (Zoonoses::RecordEuthanasia) e à
# saída `death` do canil (Zoonoses::ExitShelter). Quem chama já tem o animal
# travado FOR UPDATE (a primeira trava das quatro escritas do canil: animal →
# estada → coleira → observação) e já conferiu que ele está active ou missing.
# Na mesma transação:
#   - o animal vai a deceased com status_on = `on`, version + 1
#     (`animal.changed` só com o id);
#   - a coleira ativa (FOR UPDATE) sai com removal_reason death no mesmo dia,
#     ou no dia em que foi posta, se for depois (lançamento retroativo da
#     morte; `collar.removed` só com o id).
# A estada aberta e a observação aberta não mudam aqui: a estada fecha só pela
# saída, a observação pelo desfecho (Task 12).
module Zoonoses
  module AnimalDeath
    REMOVAL_REASON = "death".freeze

    module_function

    def apply!(animal:, on:)
      animal.update!(status: "deceased", status_on: on, version: animal.version + 1)
      DomainEvents.publish("animal.changed", animal_id: animal.id)

      collar = Collar.active.lock.find_by(animal_id: animal.id)
      return unless collar

      collar.update!(removed_on: [ on, collar.placed_on ].max, removal_reason: REMOVAL_REASON)
      DomainEvents.publish("collar.removed", collar_id: collar.id)
    end
  end
end
