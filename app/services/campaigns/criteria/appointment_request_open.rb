# Pedido de agendamento aberto agora (sem período), por tipo e destino opcionais.
module Campaigns
  module Criteria
    class AppointmentRequestOpen
      def self.relation(params)
        scope = AppointmentRequest.where(status: "open")
        scope = scope.where(kind: params["kinds"]) if params["kinds"]
        scope = scope.where(target_unit_id: params["target_unit_id"]) if params["target_unit_id"]
        scope.select(:citizen_id)
      end
    end
  end
end
