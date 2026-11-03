# "Minhas viagens" do cidadão (ADR 0048; contrato §8; §14 T14). Forma fixa e
# sem o que é da central ou do laudo: nunca veículo, motorista, endereço,
# acompanhante (só se há), procedimento, CID, justificativa nem motivo.
#
#   { items: [ { id, date, departure_at, boarding: { label },
#                destination: { name, provider_name|null }, status, companion } ],
#     tfd: [ { id, status, destination_name, appointment_at|null,
#              allowance_total_cents|null, paid } ] }
#
# items: passageiros não retirados do paciente (canceladas inclusive, com a
# situação da viagem): TODAS as viagens de hoje em diante primeiro (as mais
# próximas, se passarem de 50), depois as de hoje − 90 dias até ontem, da mais
# recente para trás, até 50 no total — mostradas em departure_at CRESCENTE
# (W8; FW12). `id` é o do passageiro.
# `date` AAAA-MM-DD (dia local da saída), horas ISO 8601 com o fuso da cidade.
# tfd (só com `tfd: true`): processos fora de `draft`, mais recentes primeiro;
# `returned` sai como `returned` (o rótulo "Em revisão pelo seu médico" é do
# wpda); `allowance_total_cents` = soma das ajudas de custo (paciente e
# acompanhante), nula antes do cálculo; `paid` quando há total positivo e a
# soma dos pagamentos o alcança (total 0 ou nulo → false, FW10). Leitura nominal: quem chama grava a trilha. Sem paciente:
# listas vazias.
module Transport
  module CitizenView
    WINDOW_DAYS = 90
    LIMIT = 50

    module_function

    def call(patient_id:, tfd:, today: Time.zone.today)
      return { items: [], tfd: [] } unless patient_id

      { items: items(patient_id, today), tfd: tfd ? tfd_cases(patient_id) : [] }
    end

    def items(patient_id, today)
      scope = TransportTripPassenger.active.where(patient_id: patient_id).joins(:transport_trip)
                                    .includes(:transport_trip, :transport_trip_stop, :transport_destination)
      upcoming = scope.where("transport_trips.date >= ?", today)
                      .order("transport_trips.departure_at ASC, transport_trip_passengers.id ASC").limit(LIMIT).to_a
      past = scope.where("transport_trips.date >= ? AND transport_trips.date < ?", today - WINDOW_DAYS, today)
                  .order("transport_trips.departure_at DESC, transport_trip_passengers.id DESC").limit(LIMIT - upcoming.size).to_a
      (past.reverse + upcoming).map do |rider|
        trip = rider.transport_trip
        { id: rider.id, date: trip.date.iso8601, departure_at: trip.departure_at.in_time_zone.iso8601,
          boarding: { label: rider.transport_trip_stop.label },
          destination: { name: rider.transport_destination.name, provider_name: rider.provider_name },
          status: trip.status, companion: !rider.companion_attendance.nil? }
      end
    end

    def tfd_cases(patient_id)
      cases = TfdCase.where(patient_id: patient_id).where.not(status: "draft").includes(:transport_destination)
                     .order(submitted_at: :desc, id: :asc).to_a
      ids = cases.map(&:id)
      totals = TfdAllowance.where(tfd_case_id: ids).group(:tfd_case_id).sum(:total_cents)
      paid = TfdPayment.where(tfd_case_id: ids).group(:tfd_case_id).sum(:amount_cents)
      cases.map do |tfd|
        total = totals[tfd.id]
        { id: tfd.id, status: tfd.status, destination_name: tfd.transport_destination.name,
          appointment_at: tfd.appointment_at&.in_time_zone&.iso8601,
          allowance_total_cents: total, paid: total.to_i.positive? && paid.fetch(tfd.id, 0) >= total }
      end
    end

    private_class_method :items, :tfd_cases
  end
end
