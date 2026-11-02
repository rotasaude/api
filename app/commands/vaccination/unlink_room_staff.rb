# Desvincula a equipe da sala: revoga o vínculo ativo, uma vez (trigger).
# Vínculo ativo inexistente (inclusive o já desfeito) → :not_found. Evento
# `vaccine_room_staff.revoked` só com ids.
module Vaccination
  module UnlinkRoomStaff
    module_function

    # -> Result.ok(link:) | fail(:invalid_request, details: { path: }) | fail(:not_found)
    def call(room:, user_id:, role:, by:)
      return refuse("role") unless Catalog::ROOM_ROLES.include?(role)
      return refuse("user_id") unless user_id.is_a?(String)

      VaccineRoomStaff.transaction(requires_new: true) do
        link = VaccineRoomStaff.active.lock.find_by(vaccine_room_id: room.id, user_id: user_id, role: role)
        next Result.fail(:not_found) unless link

        link.update!(revoked_at: Time.current, revoked_by_user: by)
        DomainEvents.publish("vaccine_room_staff.revoked", vaccine_room_id: room.id, staff_user_id: link.user_id, user_id: by.id)
        Result.ok(link: link)
      end
    end

    def refuse(path) = Result.fail(:invalid_request, details: { path: path, problems: [ { path: path, error: "invalid_request" } ] })
    private_class_method :refuse
  end
end
