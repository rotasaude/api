# POST/DELETE /pharmacy/admin/locations/:id/staff (contrato §3): vincula e
# desvincula `{ user_id, role }`. Só municipal_admin, com step-up. POST devolve
# o local com a equipe (201); DELETE → 204. Sem e-mail em resposta nenhuma.
# Módulo 29: aceita também o local `cold_chain_central` (papel só `stock_keeper`),
# com `vaccination` utilizável mesmo sem `pharmacy`; a equipe da sala
# (`vaccine_room`) é pelo /vaccination/admin, aqui é 404.
module Pharmacy
  module Admin
    class StaffController < BaseController
      include ::VaccinationGate

      skip_before_action :require_pharmacy!
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

      # O interruptor é o do tipo do local: pharmacy para central/unit (e para
      # id desconhecido), vaccination para a rede de frio; a sala → 404.
      def load_location
        location = StockLocation.find_by(id: params[:id]) if uuid?(params[:id])
        return not_found if location&.vaccine_room?

        location&.cold_chain_central? ? require_vaccination! : require_pharmacy!
        return if performed?

        @location = location
        not_found unless @location
      end
    end
  end
end
