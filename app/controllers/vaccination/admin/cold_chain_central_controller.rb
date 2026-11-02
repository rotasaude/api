# POST /vaccination/admin/cold_chain_central (§15 V2/D4): cria a rede de frio
# municipal (uma só). Só municipal_admin, com step-up; devolve a AdminLocation
# do 27a (201). A equipe vai por /pharmacy/admin/locations/:id/staff.
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
    end
  end
end
