# POST /vaccination/admin/cold_chain_central (§15 V2/D4): cria a rede de frio
# municipal (uma só). Só municipal_admin, com step-up; devolve a AdminLocation
# do 27a (201). A equipe vai por /pharmacy/admin/locations/:id/staff.
# PATCH (módulo 27b, Q13/Q23): `{ cnes, name? }`, o CNES da rede de frio (dado de
# origem do envio à BNAFAR; exige só a `vaccination`, nunca o `bnafar`).
module Vaccination
  module Admin
    class ColdChainCentralController < BaseController
      before_action { forbid unless admin? }
      before_action :require_step_up!

      def create
        result = CreateColdChainCentral.call(name: body_param("name"), by: Current.user)
        return render_failure(result) if result.failure?

        render json: Pharmacy::Json.admin_locations([ result.payload.fetch(:location) ]).first, status: :created
      end

      def update
        result = UpdateColdChainCentral.call(attrs: body, by: Current.user)
        return render_failure(result) if result.failure?

        render json: Pharmacy::Json.admin_locations([ result.payload.fetch(:location) ]).first
      end
    end
  end
end
