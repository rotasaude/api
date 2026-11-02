# Formas JSON da administração da sala de vacina (§15 V2/D4). Só ids, nomes de
# sala/unidade e dados do profissional da equipe (nome e CBO); nunca e-mail.
module Vaccination
  module Json
    module_function

    # Salas com a equipe ativa:
    # { id, name, active, health_unit: { id, name }, stock_location_id, staff: [ { user_id, name|null, role, cbo|null } ] }
    def rooms(rooms)
      rooms = rooms.to_a
      links = VaccineRoomStaff.active.includes(user: :professional).where(vaccine_room_id: rooms.map(&:id)).group_by(&:vaccine_room_id)
      rooms.map do |room|
        staff = (links[room.id] || []).map do |link|
          { user_id: link.user_id, name: link.user.professional&.professional_name, role: link.role,
            cbo: Access.cbo_codes(link.user, room.health_unit_id).first }
        end
        { id: room.id, name: room.name, active: room.active, health_unit: { id: room.health_unit.id, name: room.health_unit.name },
          stock_location_id: room.stock_location_id,
          staff: staff.sort_by { |member| [ member[:name].to_s, member[:role], member[:user_id] ] } }
      end
    end

    def room(room) = rooms([ room ]).first

    # { go_live_on: "YYYY-MM-DD"|nil }
    def settings(setting) = { "go_live_on" => setting.go_live_on&.iso8601 }

    # { id (stock_location_id), name, kind, health_unit|null, active, roles, room_id|null }
    def my_location(location, roles:, room_id: nil)
      Pharmacy::Json.location(location).merge(roles: roles.to_a.sort, room_id: room_id)
    end
  end
end
