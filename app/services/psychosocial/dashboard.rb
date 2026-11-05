# Painel do CAPS (ADR 0049; contrato §11, P11, P14, P46):
#   GET /psychosocial/dashboard?month=YYYY-MM&health_unit_id?
# Só contagens: nenhum nome, CPF, CNS, CID, texto nem id de paciente. Sem trilha.
#
#   { month:,
#     enrollments_active: [ { health_unit_id:, name:, caps_modality:, count: } ],
#     new_in_month:, closed_by_destination: { "01" => n, … },
#     care_plans_overdue:, actions_by_instrument: { raas_psi:, bpa_c:, bpa_i: },
#     bed_occupancy: { nights:, bed_days: }, raas_month: { open:, closed:, exported:, no_actions: } }
#
#  - mês no calendário do fuso da cidade; `units` é o recorte JÁ autorizado
#    pelo controlador (lotação da coordenação, ou todos os CAPS ativos);
#  - matrículas ativas = abertas no fim do mês (no mês corrente, hoje): início
#    até lá e sem encerramento até lá; uma linha por CAPS (inclusive com 0),
#    pelo nome do CAPS (P46: o painel por unidade não muda);
#  - novas = `started_on` no mês; encerradas = `closed_on` no mês, por código de
#    destino (o rótulo vem de `options`; todo código da lista de destinos,
#    inclusive com 0);
#  - PTS vencidos = a situação de HOJE (Psychosocial::CarePlanReview.due), em
#    qualquer mês pedido;
#  - ações = as não canceladas do mês, por instrumento (o mês gravado na ação);
#  - ocupação (só CAPS com leito): noites = noites ocupadas no mês até o fim do
#    mês ou hoje (a regra de noite do NightLimit; permanência aberta, dentro
#    ou além do previsto, conta a noite de hoje); leitos-dia = leitos ativos AGORA × dias do
#    mesmo intervalo;
#  - RAAS do mês = registros do mês na janela da matrícula (P37), por estado,
#    e `no_actions` = o aviso do P14 (sem ação RAAS não cancelada do mês; não
#    bloqueia nada);
#  - supressão (::Admin::SmallCount.small?) DEPOIS de agregar: 1 a 4 vira
#    "lt5" (cada contagem, as somas de noites e leitos-dia também); 0 fica 0.
module Psychosocial
  module Dashboard
    LESS_THAN_FIVE = "lt5".freeze
    INSTRUMENTS = Catalog::INSTRUMENTS

    module_function

    # units: [HealthUnit] CAPS ativos; month: Date. -> Hash
    def call(units:, month:, now: Time.current)
      units = units.to_a
      ids = units.map(&:id)
      month = month.to_date.beginning_of_month
      today = now.in_time_zone.to_date
      last = month.end_of_month
      through = [ last, today ].min
      { month: month.strftime("%Y-%m"),
        enrollments_active: enrollments_active(units, through),
        new_in_month: suppress(PsychosocialEnrollment.where(health_unit_id: ids, started_on: month..last).count),
        closed_by_destination: closed_by_destination(ids, month..last),
        care_plans_overdue: suppress(CarePlanReview.overdue_count(units: units, today: today)),
        actions_by_instrument: actions_by_instrument(ids, month),
        bed_occupancy: bed_occupancy(units.select(&:night_capable?), month, through),
        raas_month: raas_month(ids, month) }
    end

    def suppress(count) = ::Admin::SmallCount.small?(count) ? LESS_THAN_FIVE : count

    def enrollments_active(units, through)
      counts = PsychosocialEnrollment.where(health_unit_id: units.map(&:id)).where(started_on: ..through)
                                     .where("closed_on IS NULL OR closed_on > ?", through).group(:health_unit_id).count
      units.sort_by { |unit| [ unit.name, unit.id ] }.map do |unit|
        { health_unit_id: unit.id, name: unit.name, caps_modality: unit.caps_modality, count: suppress(counts.fetch(unit.id, 0)) }
      end
    end

    def closed_by_destination(ids, range)
      counts = PsychosocialEnrollment.where(health_unit_id: ids, closed_on: range).group(:destination).count
      codes = (Raas.config.fetch("destinations").keys - [ "00" ] | counts.keys).sort
      codes.to_h { |code| [ code, suppress(counts.fetch(code, 0)) ] }
    end

    def actions_by_instrument(ids, month)
      counts = PsychosocialAction.where(health_unit_id: ids, month: month, cancelled_at: nil).group(:instrument).count
      INSTRUMENTS.to_h { |instrument| [ instrument, suppress(counts.fetch(instrument, 0)) ] }
    end

    def bed_occupancy(units, month, through)
      ids = units.map(&:id)
      window = month..through
      from = month.in_time_zone
      to = (month.end_of_month + 1).in_time_zone
      # "Esta noite" é a regra do NightLimit.effective_end (P62), com `through`
      # no lugar de hoje: a aberta ocupa ao menos até o dia seguinte ao último
      # dia contado, dentro ou além do previsto; o recorte `window` limita o resto.
      stays = PsychosocialNightStay.where(health_unit_id: ids).where(started_at: ...to).where("ended_at IS NULL OR ended_at > ?", from)
      nights = stays.sum do |stay|
        NightLimit.nights(stay, today: through).count { |night| window.cover?(night) }
      end
      beds = PsychosocialBed.where(health_unit_id: ids, active: true).count
      { nights: suppress(nights), bed_days: suppress(beds * [ (through - month).to_i + 1, 0 ].max) }
    end

    def raas_month(ids, month)
      records = MonthProblems.in_window(ids, month)
      statuses = records.group("psychosocial_monthly_records.status").count
      idle = records.where.not(<<~SQL.squish).count
        EXISTS (SELECT 1 FROM psychosocial_action_participants p
                  JOIN psychosocial_actions a ON a.id = p.psychosocial_action_id
                 WHERE p.psychosocial_enrollment_id = psychosocial_monthly_records.psychosocial_enrollment_id
                   AND a.health_unit_id = psychosocial_monthly_records.health_unit_id
                   AND a.month = psychosocial_monthly_records.month
                   AND a.cancelled_at IS NULL AND a.instrument = 'raas_psi')
      SQL
      Catalog::MONTHLY_STATUSES.to_h { |status| [ status, suppress(statuses.fetch(status, 0)) ] }
                               .merge("no_actions" => suppress(idle)).symbolize_keys
    end

    private_class_method :enrollments_active, :closed_by_destination, :actions_by_instrument, :bed_occupancy, :raas_month
  end
end
