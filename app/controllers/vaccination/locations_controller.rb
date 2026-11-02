# GET /vaccination/my_locations (§15 V2/D2): as salas da pessoa com o papel em
# cada e a rede de frio onde ela é almoxarife. O almoxarife da rede de frio
# recebe também as salas ativas com `roles: []` (destinos da transferência).
module Vaccination
  class LocationsController < BaseController
    def index
      return unless query_only!

      render json: { locations: rooms_part + central_part }
    end

    private

    def rooms_part
      mine = Access.rooms_for(Current.user)
      rows = mine.map { |room| Json.my_location(room.stock_location, roles: Access.room_roles(user: Current.user, room: room), room_id: room.id) }
      return rows unless keeper?

      others = VaccineRoom.active_rooms.includes(:stock_location, :health_unit).where.not(id: mine.map(&:id)).order(:name, :id)
      rows + others.map { |room| Json.my_location(room.stock_location, roles: [], room_id: room.id) }
    end

    def central_part
      central = StockLocation.where(kind: "cold_chain_central").includes(:health_unit).first
      return [] unless central

      roles = Access.cold_chain_roles(user: Current.user, location: central)
      roles.empty? ? [] : [ Json.my_location(central, roles: roles) ]
    end

    def keeper?
      central = StockLocation.active_locations.find_by(kind: "cold_chain_central")
      central && Access.cold_chain_roles(user: Current.user, location: central).include?("stock_keeper")
    end
  end
end
