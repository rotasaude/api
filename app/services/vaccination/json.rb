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

    # <immunization> do contrato §2 (nominal: quem chama grava a trilha).
    # `entry`: a entrada `application` da fila RNDS (ou nil); `rnds.status` é
    # `not_sent` sem entrada, ou com a entrada `pending` e o envio desligado.
    # O `can_cancel` (§15 V6) entra com a Task 8, que conhece quem lê.
    def immunization(record, entry:, rnds_usable:)
      product = Immunobiologicals.find(record.immunobiological_code)
      { id: record.id,
        immunobiological: { code: record.immunobiological_code, name: product&.name },
        dose: { code: record.dose_code, name: Terminologies.name("dose", record.dose_code) },
        strategy: record.strategy, care_group: record.care_group, route: record.route, site: record.site,
        maternal_condition: record.maternal_condition, applied_at: record.applied_at,
        lot: lot(record, product), transcription: record.transcription,
        room: record.vaccine_room && { id: record.vaccine_room.id, name: record.vaccine_room.name,
                                       health_unit: { id: record.vaccine_room.health_unit.id, name: record.vaccine_room.health_unit.name } },
        by: { name: record.vaccinator_user.professional&.professional_name, cbo: record.vaccinator_cbo },
        campaign_id: record.campaign_id, status: record.cancelled? ? "cancelled" : "active", cancel_reason: record.cancel_reason,
        replaces_id: record.replaces_id, replaced_by_id: record.replacement&.id,
        rnds: rnds(entry, rnds_usable) }
    end

    # Várias doses com a entrada `application` de cada uma, sem N+1 nas associações.
    def immunizations(records, rnds_usable:)
      records = records.to_a
      ActiveRecord::Associations::Preloader.new(records: records, associations: [ :replacement, :stock_lot, { vaccine_room: :health_unit }, { vaccinator_user: :professional } ]).call
      entries = RndsOutboxEntry.where(immunization_id: records.map(&:id), kind: "application").index_by(&:immunization_id)
      records.map { |record| immunization(record, entry: entries[record.id], rnds_usable: rnds_usable) }
    end

    # Lote do estoque (com o fabricante do catálogo pela chave) ou o da
    # transcrição (texto livre, sem id nem validade).
    def lot(record, product)
      lot = record.stock_lot
      return { id: nil, number: record.lot_number_text, manufacturer: { code: nil, name: record.manufacturer_text }, expires_on: nil } unless lot

      maker = product&.manufacturer(lot.manufacturer_key)
      { id: lot.id, number: lot.lot_number, manufacturer: { code: maker&.code, name: maker&.name || lot.manufacturer }, expires_on: lot.expires_on }
    end

    def rnds(entry, usable)
      status = entry.nil? || (entry.status == "pending" && !usable) ? "not_sent" : entry.status
      { status: status, sent_at: entry&.sent_at, accepted_at: entry&.accepted_at, block_reason: entry&.block_reason, error: entry&.error }
    end

    # <vial> do contrato §2: { id, lot: { id, number, immunobiological_code }, opened_at, expires_at,
    # doses_per_vial, doses_used, doses_left, status }. `used`: doses já contadas (listas).
    def vial(vial, now:, used: nil)
      used ||= vial.doses_used
      { id: vial.id, lot: { id: vial.stock_lot_id, number: vial.stock_lot.lot_number, immunobiological_code: vial.stock_lot.immunobiological_code },
        opened_at: vial.opened_at.in_time_zone.iso8601, expires_at: vial.expires_at.in_time_zone.iso8601, doses_per_vial: vial.doses_per_vial,
        doses_used: used, doses_left: [ vial.doses_per_vial - used, 0 ].max, status: vial.status(now) }
    end

    # Vários frascos com as doses usadas contadas de uma vez (sem N+1).
    def vials(vials, now:)
      vials = vials.to_a
      used = Immunization.active.where(vial_opening_id: vials.map(&:id)).group(:vial_opening_id).count
      vials.map { |record| vial(record, now: now, used: used[record.id] || 0) }
    end

    # { id (stock_location_id), name, kind, health_unit|null, active, roles, room_id|null }
    def my_location(location, roles:, room_id: nil)
      Pharmacy::Json.location(location).merge(roles: roles.to_a.sort, room_id: room_id)
    end
  end
end
