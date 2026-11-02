# Papel na sala de vacina (ADR 0047, Desvio 6): vale com o vínculo ATIVO em
# vaccine_room_staff E a Membership ATIVA health_professional E um
# ProfessionalLink ATIVO na unidade da sala com CBO de vacinador; `room_lead`
# exige o CBO 2235*. Cada um derruba o papel sozinho. Nenhum papel novo.
module Vaccination
  module Access
    module_function

    # -> Set["vaccinator", "room_lead"] (vazio sem papel)
    def room_roles(user:, room:)
      linked = VaccineRoomStaff.active.where(user_id: user.id, vaccine_room_id: room.id).pluck(:role)
      roles_for(user, room, linked)
    end

    # roles: lista (ou um papel) de Vaccination::Catalog::ROOM_ROLES.
    def allowed?(user:, room:, roles:)
      room_roles(user: user, room: room).intersect?(Set.new(Array(roles).map(&:to_s)))
    end

    # Vínculo profissional ativo, na unidade da sala, com CBO de vacinador.
    def vaccinator_link(user:, room:)
      links_of(user, room.health_unit_id).find { |link| vaccinator_cbo?(link.cbo_code) }
    end

    # Salas ATIVAS onde o usuário tem algum papel. Ordem estável: nome, id.
    def rooms_for(user)
      linked = VaccineRoomStaff.active.where(user_id: user.id).group_by(&:vaccine_room_id)
      return [] if linked.empty?

      VaccineRoom.active_rooms.includes(:health_unit, :stock_location).where(id: linked.keys).order(:name, :id).select do |room|
        roles_for(user, room, linked.fetch(room.id).map(&:role)).any?
      end
    end

    # Almoxarife (Membership + vínculo) da rede de frio: papéis do local.
    def cold_chain_roles(user:, location:)
      Pharmacy::Access.roles_at(user: user, location: location)
    end

    def cbo_codes(user, unit_id) = links_of(user, unit_id).map(&:cbo_code)
    def vaccinator_cbo?(code) = Catalog::VACCINATOR_CBO_PREFIXES.any? { |prefix| code.to_s.start_with?(prefix) }
    def nurse_cbo?(code) = code.to_s.start_with?(Catalog::ROOM_LEAD_CBO_PREFIX)

    def roles_for(user, room, linked)
      return Set.new if linked.empty?
      return Set.new unless user.memberships.active.exists?(role: "health_professional")

      codes = cbo_codes(user, room.health_unit_id)
      Set.new(linked.select do |role|
        role == "room_lead" ? codes.any? { |code| nurse_cbo?(code) } : codes.any? { |code| vaccinator_cbo?(code) }
      end)
    end

    def links_of(user, unit_id)
      ProfessionalLink.active.joins(:professional).where(professionals: { user_id: user.id }, health_unit_id: unit_id).order(:cbo_code, :id).to_a
    end

    private_class_method :roles_for, :links_of
  end
end
