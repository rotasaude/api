# POST/DELETE /pharmacy/admin/locations/:id/staff (contrato §3): vincula e
# desvincula `{ user_id, role }`. Só municipal_admin, com step-up. POST devolve
# o local com a equipe (201); DELETE → 204. Sem e-mail em resposta nenhuma.
module Pharmacy
  module Admin
    class StaffController < BaseController
      before_action { forbid unless admin? }
      before_action :require_step_up!
      before_action :load_location

      def create
        result = LinkStaff.add(location: @location, user_id: body_param("user_id"), role: body_param("role"), by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.admin_locations([ @location ]).first, status: :created
      end

      def destroy
        result = LinkStaff.remove(location: @location, user_id: body_param("user_id"), role: body_param("role"), by: Current.user)
        return render_failure(result) if result.failure?

        head :no_content
      end

      private

      def load_location
        @location = uuid?(params[:id]) && StockLocation.find_by(id: params[:id])
        not_found unless @location
      end
    end
  end
end
