# Painel da vacinação (ADR 0047; contrato §15 V8, V14 = D13 do dashboard):
#   GET /vaccination/dashboard?month=YYYY-MM&health_unit_id=
# Só contagens, sem trilha e sem dado de paciente.
#
#   { month:, suppressed: true,
#     doses_by_immunobiological: [ { immunobiological: { code, name }, room: { id, name }, count } ],
#     c2_coverage_by_team: [ { team: { id, name }, eligible, complete } ],
#     rnds: { pending, blocked, rejected, late },
#     losses: { technical, physical },
#     unchecked_cards }
#
#  - doses: ativas, aplicadas na sala no mês (a transcrição não conta: não saiu
#    do estoque da sala, como no resumo mensal);
#  - C2: crianças de 12 a 23 meses completos (aritmética de calendário) da
#    população da equipe eSF/eAP (CareLines::TeamPopulation.members), sem
#    óbito; `complete` = Vaccination::C2.met_on não nulo, com as doses ativas
#    (transcrição inclusive) e sem teto de data: é a situação de hoje;
#  - rnds: situação atual da fila (não depende do mês), Rnds::Alert. Com o
#    envio desligado, `pending` é `not_sent` e não conta (V23); `late` inclui
#    `sending`;
#  - perdas do mês, em doses: técnica = sobra dos frascos fechados no mês;
#    física = perda/vencimento com movimento (a perda `pending` não tem
#    movimento e por isso não conta);
#  - `unchecked_cards`: pacientes com alguma linha da situação vacinal sem
#    caderneta conferida (retrato de hoje, da cidade toda);
#  - supressão (::Admin::SmallCount.small?) DEPOIS de agregar, como no painel da
#    vigilância: contagem de 1 a 4 de doses, elegíveis e completas vira nil
#    (0 continua 0). `suppressed: true` avisa a tela.
module Vaccination
  module Dashboard
    module_function

    # unit: HealthUnit | nil (a cidade toda). -> Hash
    def call(month:, unit: nil, rnds_enabled:, today: Time.zone.today)
      from = Time.zone.parse("#{month}-01").beginning_of_month
      to = from + 1.month
      rooms = VaccineRoom.all
      rooms = rooms.where(health_unit_id: unit.id) if unit
      rooms = rooms.to_a
      { month: month, suppressed: true,
        doses_by_immunobiological: doses(rooms, from, to),
        c2_coverage_by_team: c2(unit, today),
        rnds: rnds(unit, rnds_enabled),
        losses: { technical: technical_loss(rooms, from, to), physical: physical_loss(rooms, unit, from, to) },
        unchecked_cards: VaccinationStatus.where(checked: false).distinct.count(:patient_id) }
    end

    def suppress(count) = ::Admin::SmallCount.small?(count) ? nil : count
    private_class_method :suppress

    def doses(rooms, from, to)
      counts = Immunization.active.where(vaccine_room_id: rooms.map(&:id), transcription: false, applied_at: from...to)
                           .group(:immunobiological_code, :vaccine_room_id).count
      by_room = rooms.index_by(&:id)
      counts.map do |(code, room_id), count|
        { immunobiological: { code: code, name: Immunobiologicals.find(code)&.name },
          room: { id: room_id, name: by_room.fetch(room_id).name }, count: suppress(count) }
      end.sort_by { |row| [ row[:immunobiological][:code], row[:room][:name], row[:room][:id] ] }
    end
    private_class_method :doses

    def c2(unit, today)
      teams = HealthTeam.where(active: true, kind: HealthTeam::PRIMARY_CARE_KINDS)
      teams = teams.where(health_unit_id: unit.id) if unit
      teams.order(:name, :id).map do |team|
        eligible, complete = c2_counts(team, today)
        { team: { id: team.id, name: team.name }, eligible: suppress(eligible), complete: suppress(complete) }
      end
    end
    private_class_method :c2

    # -> [elegíveis, completas] da equipe.
    def c2_counts(team, today)
      members = CareLines::TeamPopulation.members(team: team)
      patient_ids = members[:patient_ids] - CareLines::Facts.deceased(members[:patient_ids]).to_a
      births = Patient.where(id: patient_ids).pluck(:id, :birth_date).to_h { |id, birth| [ id, parse_date(birth) ] }
      eligible_patients = births.select { |_, birth| birth && child?(birth, today) }
      doses = c2_doses(eligible_patients.keys)
      complete = eligible_patients.count { |id, birth| Vaccination::C2.met_on(doses: doses[id], birth_date: birth) }
      citizens = Citizen.where(id: members[:citizen_ids]).pluck(:birth_date).count { |birth| (date = parse_date(birth)) && child?(date, today) }
      [ eligible_patients.size + citizens, complete ]
    end
    private_class_method :c2_counts

    def c2_doses(patient_ids)
      doses = Hash.new { |hash, key| hash[key] = [] }
      Immunization.active.where(patient_id: patient_ids, immunobiological_code: C2.codes).pluck(:patient_id, :immunobiological_code, :applied_at).each do |id, code, at|
        doses[id] << { code: Immunobiologicals.normalize(code), on: at.in_time_zone.to_date }
      end
      doses
    end
    private_class_method :c2_doses

    # 12 a 23 meses completos em `today`.
    def child?(birth, today) = today >= birth.advance(months: 12) && today < birth.advance(months: 24)
    private_class_method :child?

    def parse_date(value)
      value.present? ? Date.iso8601(value) : nil
    rescue Date::Error
      nil
    end
    private_class_method :parse_date

    def rnds(unit, enabled)
      scope = RndsOutboxEntry.joins(:immunization)
      scope = scope.where(immunizations: { health_unit_id: unit.id }) if unit
      counts = Rnds::Alert.counts(scope, rnds_enabled: enabled)
      { pending: (enabled ? counts[:pending] : 0), blocked: counts[:blocked], rejected: counts[:rejected], late: counts[:late] }
    end
    private_class_method :rnds

    def technical_loss(rooms, from, to)
      VialOpening.where(vaccine_room_id: rooms.map(&:id), closed_at: from...to).sum(:technical_loss_doses).to_i
    end
    private_class_method :technical_loss

    # Sala: o local da sala; sem filtro, também a rede de frio.
    def physical_loss(rooms, unit, from, to)
      scope = StockMovement.where(kind: %w[loss expiry], recorded_at: from...to).where.not(immunobiological_code: nil)
      scope = scope.where(stock_location_id: rooms.map(&:stock_location_id)) if unit
      -scope.sum(:quantity).to_d.to_i
    end
    private_class_method :physical_loss
  end
end
