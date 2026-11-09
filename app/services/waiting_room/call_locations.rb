# Local da chamada (ADR 0050; plano, Desvio 12; contrato §6 e §14 Q7). Só
# vale com o waiting_room_display utilizável, lido pelo chamador FORA da
# transação da cidade (`enabled:`). Desligado, o local é ignorado. Ligado, é
# obrigatório quando a unidade tem TV ativa e pareada; dado, tem de ser um
# local ativo da própria unidade. `required?` é o mesmo predicado da lista de
# locais (`location_required`, Task 12).
module WaitingRoom
  module CallLocations
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def required?(unit_id, enabled:)
      enabled && WaitingRoomDisplay.paired_active.exists?(health_unit_id: unit_id)
    end

    # -> [:ok, CallLocation | nil] | [:call_location_required, nil] | [:invalid_call_location, nil]
    def resolve(unit_id:, call_location_id:, enabled:)
      return [ :ok, nil ] unless enabled
      if call_location_id.blank?
        return required?(unit_id, enabled: enabled) ? [ :call_location_required, nil ] : [ :ok, nil ]
      end

      location = call_location_id.is_a?(String) && call_location_id.match?(UUID) &&
                 CallLocation.active.find_by(id: call_location_id, health_unit_id: unit_id)
      location ? [ :ok, location ] : [ :invalid_call_location, nil ]
    end
  end
end
