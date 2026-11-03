# Painel do transporte e do TFD (ADR 0048; contrato §9, §14 T16):
#   GET /transport/dashboard?month=YYYY-MM
# Só números, sem trilha e sem dado de paciente.
#
#   { month:, trips:, occupancy_pct:, no_shows:, km:, fuel_cents,
#     tfd_by_status: { <situação> => n }, tfd_paid_cents:, exceptions: }
#
#  - mês no calendário do fuso da cidade (Time.zone): viagens pela `date`
#    (dia local da saída), processos por `created_at`, pagamentos por `paid_on`;
#  - viagens = as `done` do mês; passageiros = os ATIVOS (não retirados) delas;
#  - occupancy_pct = round(100 × Σ lugares usados / Σ lugares do veículo), nulo
#    sem nenhuma viagem; lugares usados = passageiros que ocupam assento +
#    acompanhantes (a mesma conta do Transport::Occupancy);
#  - km = Σ (odômetro final − inicial) do diário; fuel_cents = Σ dos
#    abastecimentos do diário; as somas nunca são suprimidas;
#  - tfd_by_status: situação ATUAL dos processos criados no mês (só as com
#    processo); `{}` sem o TFD utilizável (`tfd_enabled`, lido fora da transação);
#  - supressão (::Admin::SmallCount.small?) DEPOIS de agregar: contagem de 1 a 4
#    (viagens, faltas, exceções, processos por situação) vira "lt5"; 0 fica 0.
module Transport
  module Dashboard
    LESS_THAN_FIVE = "lt5".freeze

    module_function

    # month: "YYYY-MM" já validado. -> Hash
    def call(month:, tfd_enabled:)
      first = Date.iso8601("#{month}-01")
      last = first.end_of_month
      from = first.in_time_zone
      to = (first.next_month).in_time_zone
      trip_ids = TransportTrip.where(status: "done", date: first..last).pluck(:id)
      riders = rider_counts(trip_ids)
      { month: month,
        trips: suppress(trip_ids.size),
        occupancy_pct: occupancy(trip_ids, riders[:seats_used]),
        no_shows: suppress(riders[:no_shows]),
        km: km(trip_ids),
        fuel_cents: fuel_cents(trip_ids),
        tfd_by_status: tfd_enabled ? tfd_by_status(from, to) : {},
        tfd_paid_cents: TfdPayment.where(paid_on: first..last).sum(:amount_cents).to_i,
        exceptions: suppress(riders[:exceptions]) }
    end

    def suppress(count) = ::Admin::SmallCount.small?(count) ? LESS_THAN_FIVE : count
    private_class_method :suppress

    def rider_counts(trip_ids)
      seats_used, no_shows, exceptions = TransportTripPassenger.active.where(transport_trip_id: trip_ids).pick(
        Arel.sql("COUNT(*) FILTER (WHERE takes_seat) + COUNT(*) FILTER (WHERE companion_attendance IS NOT NULL)"),
        Arel.sql("COUNT(*) FILTER (WHERE attendance = 'no_show')"),
        Arel.sql("COUNT(*) FILTER (WHERE origin = 'exception')")
      )
      { seats_used: seats_used.to_i, no_shows: no_shows.to_i, exceptions: exceptions.to_i }
    end
    private_class_method :rider_counts

    def occupancy(trip_ids, seats_used)
      seats = TransportTrip.where(id: trip_ids).joins(:transport_vehicle).sum("transport_vehicles.seats").to_i
      seats.positive? ? (100.0 * seats_used / seats).round : nil
    end
    private_class_method :occupancy

    def km(trip_ids)
      TransportTripLog.where(transport_trip_id: trip_ids).sum("odometer_end - odometer_start").to_i
    end
    private_class_method :km

    def fuel_cents(trip_ids)
      TransportTripLog.where(transport_trip_id: trip_ids).pluck(:fuel).sum do |list|
        Array(list).sum { |item| item.is_a?(Hash) ? item["amount_cents"].to_i : 0 }
      end
    end
    private_class_method :fuel_cents

    def tfd_by_status(from, to)
      TfdCase.where(created_at: from...to).group(:status).count.sort.to_h { |status, count| [ status, suppress(count) ] }
    end
    private_class_method :tfd_by_status
  end
end
