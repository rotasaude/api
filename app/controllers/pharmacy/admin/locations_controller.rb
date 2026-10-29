# GET/POST/PATCH /pharmacy/admin/locations[/:id] (contrato §3): locais de
# estoque. Só municipal_admin; escrita com step-up. Nunca se apaga: desativa-se
# (`active: false`), e só sem saldo. Escritas devolvem o objeto, sem envelope.
module Pharmacy
  module Admin
    class LocationsController < BaseController
      before_action { forbid unless admin? }
      before_action :require_step_up!, only: %i[create update]

      def index
        render json: { locations: Json.admin_locations(StockLocation.includes(:health_unit).order(:name, :id)) }
      end

      def create
        result = SaveLocation.call(attrs: body, by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.admin_locations([ result.payload.fetch(:location) ]).first, status: :created
      end

      def update
        location = uuid?(params[:id]) && StockLocation.find_by(id: params[:id])
        return not_found unless location

        result = SaveLocation.call(attrs: body, by: Current.user, location: location)
        return render_failure(result) if result.failure?

        render json: Json.admin_locations([ result.payload.fetch(:location) ]).first
      end
    end
  end
end
