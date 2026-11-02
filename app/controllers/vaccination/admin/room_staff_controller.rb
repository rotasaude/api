# POST/DELETE /vaccination/admin/rooms/:id/staff (§15 V2/D4): vincula e
# desvincula `{ user_id, role }` da sala. Só municipal_admin, com step-up.
# POST devolve a sala inteira (201); DELETE → 204.
module Vaccination
  module Admin
    class RoomStaffController < BaseController
      before_action { forbid unless admin? }
      before_action :require_step_up!
      before_action :load_room

      def create
        result = LinkRoomStaff.call(room: @room, user_id: body_param("user_id"), role: body_param("role"), by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.room(@room.reload), status: :created
      end

      def destroy
        result = UnlinkRoomStaff.call(room: @room, user_id: body_param("user_id"), role: body_param("role"), by: Current.user)
        return render_failure(result) if result.failure?

        head :no_content
      end

      private

      def load_room
        @room = uuid?(params[:id]) && VaccineRoom.find_by(id: params[:id])
        not_found unless @room
      end
    end
  end
end
