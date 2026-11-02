# GET/POST/PATCH /vaccination/admin/rooms[/:id] (§15 V2/D4): salas de vacina e
# a rede de frio municipal. Só municipal_admin; escrita com step-up. Nunca se
# apaga: desativa-se. Escritas devolvem a sala inteira, sem envelope.
module Vaccination
  module Admin
    class RoomsController < BaseController
      before_action { forbid unless admin? }
      before_action :require_step_up!, only: %i[create update]

      def index
        central = StockLocation.where(kind: "cold_chain_central").includes(:health_unit).first
        rooms = VaccineRoom.includes(:health_unit).order(:name, :id)
        render json: { rooms: Json.rooms(rooms), cold_chain_central: central && Pharmacy::Json.admin_locations([ central ]).first }
      end

      def create
        result = SaveRoom.call(attrs: body, by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.room(result.payload.fetch(:room)), status: :created
      end

      def update
        room = uuid?(params[:id]) && VaccineRoom.find_by(id: params[:id])
        return not_found unless room

        result = SaveRoom.call(attrs: body, by: Current.user, room: room)
        return render_failure(result) if result.failure?

        render json: Json.room(result.payload.fetch(:room))
      end
    end
  end
end
