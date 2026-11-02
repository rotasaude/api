# Vincula a equipe da sala (ADR 0047, Desvio 6). Exige a Membership ATIVA
# health_professional (`role_not_granted`) e um vínculo profissional ATIVO na
# unidade da sala (`professional_link_missing`) com CBO de vacinador
# (`cbo_not_allowed`); `room_lead` só com o CBO 2235* (`room_lead_requires_nurse`).
# O vínculo nunca se apaga: vincular de novo grava outra linha. Eventos
# `vaccine_room_staff.linked` só com ids.
module Vaccination
  module LinkRoomStaff
    module_function

    # -> Result.ok(link:) | fail(:invalid_request, details: { path: }) | fail(:not_found) |
    # fail(:role_not_granted | :professional_link_missing | :cbo_not_allowed | :room_lead_requires_nurse) |
    # fail(:location_inactive) | fail(:already_linked).
    def call(room:, user_id:, role:, by:)
      invalid = invalid_body(user_id, role)
      return invalid if invalid

      user = User.find_by(id: user_id)
      return Result.fail(:not_found) unless user&.active?

      VaccineRoomStaff.transaction(requires_new: true) do
        locked = VaccineRoom.lock("FOR SHARE").find(room.id)
        next Result.fail(:location_inactive) unless locked.active
        next refuse(:role_not_granted, "user_id") unless user.memberships.active.exists?(role: "health_professional")

        codes = Access.cbo_codes(user, locked.health_unit_id)
        next refuse(:professional_link_missing, "user_id") if codes.empty?
        next refuse(:cbo_not_allowed, "user_id") unless codes.any? { |code| Access.vaccinator_cbo?(code) }
        next refuse(:room_lead_requires_nurse, "role") if role == "room_lead" && codes.none? { |code| Access.nurse_cbo?(code) }
        next Result.fail(:already_linked) if VaccineRoomStaff.active.exists?(vaccine_room_id: locked.id, user_id: user.id, role: role)

        link = VaccineRoomStaff.create!(vaccine_room: locked, user: user, role: role, granted_by_user: by, granted_at: Time.current)
        DomainEvents.publish("vaccine_room_staff.linked", vaccine_room_id: locked.id, staff_user_id: user.id, user_id: by.id)
        Result.ok(link: link)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:already_linked)
    end

    def invalid_body(user_id, role)
      return refuse(:invalid_request, "role") unless Catalog::ROOM_ROLES.include?(role)
      return refuse(:invalid_request, "user_id") unless user_id.is_a?(String)

      nil
    end

    # Todo 422 traz `problems` com ao menos um problema (regra do módulo).
    def refuse(error, path) = Result.fail(error, details: { path: path, problems: [ { path: path, error: error.to_s } ] })

    private_class_method :invalid_body, :refuse
  end
end
