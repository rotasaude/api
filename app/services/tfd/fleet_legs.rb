# Trechos de frota do TFD ligados aos passageiros da viagem (plano, Desvio 13;
# preflight R9). Única porta do transporte para o TFD:
#   - complete!(trip): no fechamento da viagem (Transport::CloseTrip, na mesma
#     transação), marca `done` os trechos de frota abertos (ida e/ou volta, T38)
#     de cada passageiro ativo `boarded` (com o deslocamento e, fechado o par,
#     a alimentação);
#   - complete_passenger!(passenger, by:): na correção no_show → boarded
#     (Transport::CorrectAttendance) e no trecho registrado depois do
#     fechamento (Tfd::AddLeg), os trechos abertos daquele passageiro.
# Só viagem `done`. Ordem das travas (Ruling da Task 8): a VIAGEM primeiro
# (FOR UPDATE aqui, mesmo que o chamador já a tenha — na mesma transação é
# a mesma trava), depois o processo e o trecho (Tfd::CompleteLeg.complete!).
# O CorrectAttendance trava a viagem antes de conferir os trechos feitos, e
# a rota da passagem recusa trecho de frota (fleet_leg_by_trip): nenhum
# trecho de frota fica feito sem a trava da viagem. Processo que não aceita
# mais trecho (cancelado) fica de fora, sem derrubar o fechamento (no log,
# só ids e o motivo). Os processos são travados na ordem de tfd_case_id
# (duas viagens fechando ao mesmo tempo com o mesmo grupo não se travam em
# ordem inversa).
module Tfd
  module FleetLegs
    module_function

    # -> [TfdLeg] completados
    def complete!(trip, by: nil)
      TransportTrip.transaction(requires_new: true) do
        locked = TransportTrip.lock.find(trip.id)
        next [] unless locked.status == "done"

        by ||= locked.transport_trip_log&.closed_by_user
        settings = Transport::Settings.current
        legs = TfdLeg.joins(:transport_trip_passenger).includes(:transport_trip_passenger)
                     .where(mode: "fleet", done_at: nil,
                            transport_trip_passengers: { transport_trip_id: locked.id, attendance: "boarded", removed_at: nil })
                     .order(:tfd_case_id, :date, :created_at, :id).to_a
        legs.filter_map { |leg| complete(leg, by, settings) }
      end
    end

    # -> [TfdLeg] completados
    def complete_passenger!(passenger, by: nil)
      TransportTrip.transaction(requires_new: true) do
        locked = TransportTrip.lock.find(passenger.transport_trip_id)
        rider = TransportTripPassenger.find(passenger.id)
        next [] unless locked.status == "done" && rider.attendance == "boarded" && !rider.removed?

        by ||= locked.transport_trip_log&.closed_by_user
        settings = Transport::Settings.current
        TfdLeg.where(transport_trip_passenger_id: rider.id, mode: "fleet", done_at: nil).order(:date, :created_at, :id)
              .to_a.filter_map { |leg| complete(leg, by, settings) }
      end
    end

    def complete(leg, by, settings)
      result = CompleteLeg.complete!(leg, by: by, settings: settings)
      return leg if result.ok?

      Rails.logger.info("tfd.fleet_leg_skipped tfd_leg_id=#{leg.id} tfd_case_id=#{leg.tfd_case_id} reason=#{result.reason}")
      nil
    end
    private_class_method :complete
  end
end
