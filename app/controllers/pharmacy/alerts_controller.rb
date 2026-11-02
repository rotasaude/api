# GET /pharmacy/alerts (contrato §9 e H10/H12): as cinco contagens do local, sem
# trilha e sem dado pessoal. `location_id` obrigatório e legível pelo usuário
# (qualquer papel nele; o almoxarife do central lê todos): inexistente → 422,
# sem papel → 403.
# Módulo 29 (Desvio 4): só de medicamento; local de vacina → 404.
module Pharmacy
  class AlertsController < BaseController
    include LocationReading

    def show
      return unless query_only!(:location_id)

      location = required_location or return
      return not_found if Stock::Domain.immunobiological?(location)

      render json: Alerts.call(location: location, today: Time.zone.today, settings: Settings.current)
    end
  end
end
