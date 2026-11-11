# Trava da manifestação (ADR 0051; Desvio 4; contrato §2). Toda ação sobre
# uma manifestação começa aqui, DENTRO da transação do comando, e a ordem é a
# de Citizens::Erase: primeiro o cidadão, depois a manifestação. Assim a
# exclusão LGPD (que trava o par FOR UPDATE e anula citizen_id) e uma ação da
# equipe nunca se cruzam.
#
# `expected_state` é o controle de concorrência (não há lock_version): estado
# atual diferente → 409 manifestation_changed, nada gravado.
module Ombudsman
  module Lock
    module_function

    # -> OmbudsmanManifestation (travada FOR UPDATE) | nil (não existe).
    # Lê citizen_id sem trava, trava o cidadão FOR KEY SHARE (quando há) e então
    # a manifestação; se o citizen_id mudou no intervalo (a exclusão o anulou),
    # recomeça uma vez — com o novo valor não há mais cidadão a travar.
    def manifestation!(id)
      raise ArgumentError, "Ombudsman::Lock exige a transação do comando" unless OmbudsmanManifestation.connection.transaction_open?

      2.times do
        row = OmbudsmanManifestation.where(id: id).pick(:id, :citizen_id)
        return nil unless row

        citizen_id = row.last
        Citizen.lock("FOR KEY SHARE").find_by(id: citizen_id) if citizen_id
        locked = OmbudsmanManifestation.lock("FOR UPDATE").find_by(id: id)
        return nil unless locked
        return locked if locked.citizen_id == citizen_id
      end
      OmbudsmanManifestation.lock("FOR UPDATE").find_by(id: id)
    end

    # -> Result.fail | nil. `expected_state` ausente, não-String ou fora de
    # STATES → 422 invalid_request `path: "expected_state"`; diferente do
    # estado atual → 409 manifestation_changed.
    def check(manifestation, expected_state)
      unless expected_state.is_a?(String) && Catalog::STATES.include?(expected_state)
        return Result.fail(:invalid_request, details: { path: "expected_state",
                                                        problems: [ { error: "invalid_request", path: "expected_state" } ] })
      end
      return nil if manifestation.state == expected_state

      Result.fail(:manifestation_changed)
    end
  end
end
