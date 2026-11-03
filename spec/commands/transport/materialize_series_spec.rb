require "rails_helper"

# Módulo 30, Task 7 (ADR 0048; contrato §4, §14 T6; Review Focus 2): a série
# recorrente vira viagens nos próximos 21 dias — entra na viagem do dia e
# destino com vaga (a de saída mais próxima), cria a planned sem escala quando
# não há viagem, e vira pendência (nunca excesso) quando nenhuma cabe.
RSpec.describe Transport::MaterializeSeries do
  let!(:city) { transport_city! }
  let(:dest) { destination! }
  let(:monday) { Date.current.next_occurring(:monday) }
  let(:patient) { transport_patient! }
  let(:base_attrs) do
    { "patient_id" => patient.id, "destination_id" => dest.id, "weekdays" => [ 1, 3, 5 ],
      "appointment_time" => "07:00", "departure_time" => "05:30", "return_time" => "13:00",
      "boarding_label" => "Posto do Distrito", "starts_on" => monday.iso8601, "wheelchair" => false }
  end
  let(:series) { save_series!(base_attrs) }

  def save_series!(attrs)
    result = Transport::SaveSeries.call(attrs: attrs, by: dispatcher!)
    raise "SaveSeries falhou: #{result.to_h}" unless result.ok?

    result.payload[:series]
  end

  def series_passengers(s = series) = TransportTripPassenger.joins(:transport_trip).where(transport_series_id: s.id, removed_at: nil)

  it "Review Focus 2: cria planned às 05:30 locais nos dias da série, e rodar de novo não duplica passageiro, viagem nem pendência" do
    result = described_class.call(series: series, today: monday)
    trips = TransportTrip.where(transport_series_id: series.id).order(:date)
    expect(trips.map { |t| t.date.cwday }.uniq).to eq([ 1, 3, 5 ])
    expect(trips.map { |t| t.departure_at.in_time_zone.strftime("%H:%M") }.uniq).to eq([ "05:30" ])
    expect(trips.map { |t| t.return_at.in_time_zone.strftime("%H:%M") }.uniq).to eq([ "13:00" ])
    # 05:30 em São Paulo (-03:00) = 08:30 UTC: o erro de fuso daria 02:30 ou o dia errado.
    expect(trips.map { |t| t.departure_at.utc.strftime("%H:%M") }.uniq).to eq([ "08:30" ])
    expect(trips.all? { |t| t.departure_at.in_time_zone.to_date == t.date }).to be(true)
    expect(trips.first.date).to eq(monday)
    expect(trips.count).to eq(9)
    expect(trips.map(&:status).uniq).to eq([ "planned" ])
    expect(trips.map(&:transport_vehicle_id).uniq).to eq([ nil ])
    expect(trips.map(&:created_by_user_id).uniq).to eq([ series.created_by_user_id ])
    expect(result).to eq(added: 9, created_trips: 9, pending: 0, failed: 0)

    stops = trips.first.transport_trip_stops.map { |s| [ s.position, s.kind, s.label, s.transport_destination_id ] }
    expect(stops).to eq([ [ 1, "boarding", "Posto do Distrito", nil ], [ 2, "destination", dest.name, dest.id ] ])
    passenger = series_passengers.find_by!(transport_trip_id: trips.first.id)
    expect(passenger).to have_attributes(origin: "series", patient_id: patient.id, added_by_user_id: nil, takes_seat: true,
                                         wheelchair: false, transport_destination_id: dest.id)
    expect(passenger.appointment_at.in_time_zone.strftime("%Y-%m-%d %H:%M")).to eq("#{monday.iso8601} 07:00")

    counts = -> { [ TransportTripPassenger.count, TransportTrip.count, TransportTripStop.count, TransportPendingItem.count ] }
    expect { described_class.call(series: series, today: monday) }.not_to(change(counts, :call))
  end

  it "Review Focus 2: pendência não duplica — a segunda execução no mesmo dia não muda passageiros, viagens nem pendências" do
    full = trip!(date: monday, departure: "05:00", back: "12:00", vehicle: vehicle!(seats: 1, wheelchair_spots: 0),
                 driver: driver_user!.transport_driver, status: "confirmed", destination: dest)
    passenger!(full)
    first = described_class.call(series: series, today: monday)
    expect(first).to eq(added: 8, created_trips: 8, pending: 1, failed: 0)
    counts = -> { [ TransportTripPassenger.count, TransportTrip.count, TransportTripStop.count, TransportPendingItem.count ] }
    before = counts.call
    second = described_class.call(series: series, today: monday)
    expect(counts.call).to eq(before)
    expect(second).to eq(added: 0, created_trips: 0, pending: 0, failed: 0)
    expect(TransportPendingItem.where(transport_series_id: series.id).pluck(:date)).to eq([ monday ])
  end

  it "entra na viagem confirmada do dia com vaga; cheia vira pendência, nunca excesso" do
    full = trip!(date: monday, vehicle: vehicle!(seats: 1, wheelchair_spots: 0), driver: driver_user!.transport_driver, status: "confirmed",
                 destination: dest)
    passenger!(full)
    roomy = trip!(date: monday + 2, departure: "06:00", back: "14:00", vehicle: vehicle!(seats: 4, wheelchair_spots: 0),
                  driver: driver_user!.transport_driver, status: "confirmed", destination: dest)
    described_class.call(series: series, today: monday)
    expect(TransportPendingItem.find_by(transport_series_id: series.id, date: monday).reason).to eq("no_seat")
    expect(full.transport_trip_passengers.where(removed_at: nil).count).to eq(1)
    expect(TransportTrip.where(date: monday).count).to eq(1)
    expect(series_passengers.where(transport_trip_id: roomy.id).count).to eq(1)
    expect(TransportTrip.where(date: monday + 2).count).to eq(1)
  end

  it "cadeirante sem vaga de cadeira → no_wheelchair_spot; entre as viagens do dia, a de saída mais próxima é a escolhida" do
    wheel = save_series!(base_attrs.merge("wheelchair" => true, "weekdays" => [ 1 ]))
    no_spot = trip!(date: monday, departure: "05:30", back: "12:00", vehicle: vehicle!(seats: 10, wheelchair_spots: 0),
                    driver: driver_user!.transport_driver, status: "confirmed", destination: dest)
    described_class.call(series: wheel, today: monday)
    expect(TransportPendingItem.find_by!(transport_series_id: wheel.id, date: monday).reason).to eq("no_wheelchair_spot")
    expect(no_spot.transport_trip_passengers.count).to eq(0)

    other = save_series!(base_attrs.merge("patient_id" => transport_patient!.id, "weekdays" => [ 3 ]))
    far = trip!(date: monday + 2, departure: "09:00", back: "15:00", destination: dest)
    near = trip!(date: monday + 2, departure: "05:00", back: "11:00", destination: dest)
    described_class.call(series: other, today: monday)
    expect(series_passengers(other).where(transport_trip_id: near.id).count).to eq(1)
    expect(series_passengers(other).where(transport_trip_id: far.id).count).to eq(0)
    passenger = series_passengers(other).find_by!(transport_trip_id: near.id)
    expect(passenger.takes_seat).to be(true)
  end

  it "viagem de outro destino, cancelada ou feita não serve; a do destino da série sim" do
    other_dest = destination!(name: "Londrina", ibge: "4113700", km: 380)
    trip!(date: monday, departure: "05:30", destination: other_dest)
    cancelled = trip!(date: monday, departure: "05:30", destination: dest)
    cancelled.update_columns(status: "cancelled", cancelled_at: Time.current)
    described_class.call(series: series, today: monday)
    created = TransportTrip.find_by!(date: monday, transport_series_id: series.id)
    expect(series_passengers.where(transport_trip_id: created.id).count).to eq(1)
    expect(TransportTripPassenger.where(transport_trip_id: cancelled.id).count).to eq(0)
  end

  it "embarque: reaproveita a parada de mesmo rótulo sem distinção de caixa; senão cria uma antes do primeiro destino" do
    same = trip!(date: monday, departure: "05:30", destination: dest)
    same.transport_trip_stops.find_by!(kind: "boarding").update!(label: "POSTO DO DISTRITO")
    other = trip!(date: monday + 2, departure: "05:30", destination: dest)
    described_class.call(series: series, today: monday)
    expect(same.transport_trip_stops.reload.count).to eq(2)
    expect(series_passengers.find_by!(transport_trip_id: same.id).transport_trip_stop.label).to eq("POSTO DO DISTRITO")
    stops = other.transport_trip_stops.reload.map { |s| [ s.position, s.kind, s.label ] }
    expect(stops).to eq([ [ 1, "boarding", "Praça Central" ], [ 2, "boarding", "Posto do Distrito" ], [ 3, "destination", dest.name ] ])
    expect(series_passengers.find_by!(transport_trip_id: other.id).transport_trip_stop.label).to eq("Posto do Distrito")
  end

  it "respeita início, fim, suspensão e o horizonte de 21 dias" do
    ending = save_series!(base_attrs.merge("ends_on" => (monday + 4).iso8601))
    described_class.call(series: ending, today: monday)
    expect(TransportTrip.where(transport_series_id: ending.id).order(:date).pluck(:date)).to eq([ monday, monday + 2, monday + 4 ])

    later = save_series!(base_attrs.merge("patient_id" => transport_patient!.id, "starts_on" => (monday + 7).iso8601))
    described_class.call(series: later, today: monday)
    dates = TransportTrip.where(transport_series_id: later.id).order(:date).pluck(:date)
    expect(dates.first).to eq(monday + 7)
    expect(dates.last).to eq(monday + 18) # sexta da 3ª semana; segunda +21 já está fora do horizonte
    expect(dates.size).to eq(6)

    paused = save_series!(base_attrs.merge("patient_id" => transport_patient!.id))
    paused.update!(suspended_from: monday + 2, suspend_reason: "Paciente internado no hospital")
    described_class.call(series: paused, today: monday)
    expect(series_passengers(paused).pluck("transport_trips.date")).to eq([ monday ])
  end

  it "acompanhante da série entra com o paciente e ocupa lugar" do
    with_companion = save_series!(base_attrs.merge("weekdays" => [ 1 ], "companion" => { "name" => "Maria Acompanhante", "document" => "12345678",
                                                                                           "reason" => "Paciente com limitação de mobilidade" }))
    trip = trip!(date: monday, departure: "05:30", vehicle: vehicle!(seats: 2, wheelchair_spots: 0), driver: driver_user!.transport_driver,
                 status: "confirmed", destination: dest)
    passenger!(trip)
    roomy = trip!(date: monday + 7, departure: "05:30", vehicle: vehicle!(seats: 3, wheelchair_spots: 0), driver: driver_user!.transport_driver,
                  status: "confirmed", destination: dest)
    passenger!(roomy)
    described_class.call(series: with_companion, today: monday)
    expect(TransportPendingItem.find_by!(transport_series_id: with_companion.id, date: monday).reason).to eq("no_seat")
    passenger = series_passengers(with_companion).find_by!(transport_trip_id: roomy.id)
    expect([ passenger.companion_name, passenger.companion_attendance ]).to eq([ "Maria Acompanhante", "pending" ])
    expect(Transport::Occupancy.of(roomy)[:seats_used]).to eq(3)
  end

  it "o paciente posto à mão pela origem série no dia resolve a pendência aberta desse dia" do
    full = trip!(date: monday, vehicle: vehicle!(seats: 1, wheelchair_spots: 0), driver: driver_user!.transport_driver, status: "confirmed",
                 destination: dest)
    passenger!(full)
    described_class.call(series: series, today: monday)
    pending = TransportPendingItem.find_by!(transport_series_id: series.id, date: monday)
    other = trip!(date: monday, departure: "09:00", destination: dest)
    passenger!(other, patient: patient, origin: "series", exception_reason: nil, transport_series: series)
    described_class.call(series: series, today: monday)
    expect(pending.reload.resolved_at).to be_present
    expect(TransportPendingItem.where(transport_series_id: series.id).count).to eq(1)
  end

  it "suspender tira das viagens futuras (planned e confirmed), resolve as pendências futuras e para de criar" do
    described_class.call(series: series, today: monday)
    pending_series = save_series!(base_attrs.merge("patient_id" => transport_patient!.id, "weekdays" => [ 5 ]))
    TransportPendingItem.create!(transport_series: pending_series, date: monday + 4, reason: "no_seat")
    removed_events = -> { DomainEvent.where(name: "transport.passenger_removed").count }
    expect do
      result = Transport::SuspendSeries.call(series: series, from_on: monday + 2, reason: "Transplante realizado, fim da diálise", by: dispatcher!)
      expect(result).to be_ok
    end.to change(removed_events, :call).by(8)
    left = TransportTripPassenger.joins(:transport_trip).where(transport_series_id: series.id, removed_at: nil)
    expect(left.pluck("transport_trips.date")).to eq([ monday ])
    gone = TransportTripPassenger.where(transport_series_id: series.id).where.not(removed_at: nil)
    expect(gone.map(&:remove_reason).uniq).to eq([ "Transplante realizado, fim da diálise" ])
    expect(series.reload).to have_attributes(suspended_from: monday + 2, suspend_reason: "Transplante realizado, fim da diálise")

    expect { described_class.call(series: series, today: monday) }.not_to(change { TransportTripPassenger.count })

    Transport::SuspendSeries.call(series: pending_series, from_on: monday + 1, reason: "Paciente mudou de município", by: dispatcher!)
    expect(TransportPendingItem.find_by!(transport_series_id: pending_series.id).resolved_at).to be_present
  end

  it "suspender: motivo curto ou data no passado → invalid_request, nada muda" do
    described_class.call(series: series, today: monday)
    short = Transport::SuspendSeries.call(series: series, from_on: monday, reason: "curto", by: dispatcher!)
    past = Transport::SuspendSeries.call(series: series, from_on: Date.current - 1, reason: "Transplante realizado, fim da diálise", by: dispatcher!)
    expect([ short.reason, short.details[:path] ]).to eq([ :invalid_request, "reason" ])
    expect([ past.reason, past.details[:path] ]).to eq([ :invalid_request, "from_on" ])
    expect(series.reload.suspended_from).to be_nil
    expect(series_passengers.count).to eq(9)
  end

  describe "fix round 1: dia perdido, motivo, parada órfã e savepoint por dia" do
    let(:full) do
      trip!(date: monday, vehicle: vehicle!(seats: 1, wheelchair_spots: 0), driver: driver_user!.transport_driver, status: "confirmed",
            destination: dest).tap { |t| passenger!(t) }
    end
    let(:one_day) { save_series!(base_attrs.merge("weekdays" => [ 1 ], "ends_on" => monday.iso8601)) }

    def pending_of(s) = TransportPendingItem.find_by!(transport_series_id: s.id, date: monday)

    it "sem lugar → pendência; posto à mão → resolve; retirado → a próxima execução põe o paciente de novo" do
      full
      described_class.call(series: one_day, today: monday)
      expect(pending_of(one_day).resolved_at).to be_nil
      by_hand = trip!(date: monday, departure: "09:00", destination: dest)
      placed = passenger!(by_hand, patient: patient, origin: "series", exception_reason: nil, transport_series: one_day)
      described_class.call(series: one_day, today: monday)
      expect(pending_of(one_day).resolved_at).to be_present
      Transport::RemovePassenger.call(passenger: placed, reason: "Retirado pela central por engano", by: dispatcher!)
      result = described_class.call(series: one_day, today: monday)
      expect(result).to include(added: 1, pending: 0)
      expect(series_passengers(one_day).pluck(:transport_trip_id)).to eq([ by_hand.id ])
    end

    it "viagem posta à mão cancelada → a próxima execução reabre a mesma pendência (nunca some o dia)" do
      full
      described_class.call(series: one_day, today: monday)
      by_hand = trip!(date: monday, departure: "09:00", destination: dest)
      passenger!(by_hand, patient: patient, origin: "series", exception_reason: nil, transport_series: one_day)
      described_class.call(series: one_day, today: monday)
      pending = pending_of(one_day)
      expect(pending.resolved_at).to be_present
      by_hand.update_columns(status: "cancelled", cancelled_at: Time.current)
      result = described_class.call(series: one_day, today: monday)
      expect(result).to include(pending: 1, added: 0)
      expect(pending.reload).to have_attributes(resolved_at: nil, reason: "no_seat")
      expect(TransportPendingItem.where(transport_series_id: one_day.id).count).to eq(1)
      get_items = TransportPendingItem.where(resolved_at: nil, date: monday).pluck(:transport_series_id)
      expect(get_items).to eq([ one_day.id ])
    end

    it "cadeirante com acompanhante sem lugar (cadeira livre) → no_seat, pelo que falta de fato" do
      trip = trip!(date: monday, vehicle: vehicle!(seats: 1, wheelchair_spots: 1), driver: driver_user!.transport_driver, status: "confirmed",
                   destination: dest)
      passenger!(trip)
      wheel = save_series!(base_attrs.merge("weekdays" => [ 1 ], "ends_on" => monday.iso8601, "wheelchair" => true,
                                            "companion" => { "name" => "Maria Acompanhante", "reason" => "Paciente com limitação de mobilidade" }))
      described_class.call(series: wheel, today: monday)
      expect(pending_of(wheel).reason).to eq("no_seat")
    end

    it "recusa do AddPassenger: a parada nova do dia não fica órfã, o dia conta em failed e os outros dias seguem" do
      trip = trip!(date: monday, departure: "05:30", destination: dest)
      allow(Transport::AddPassenger).to receive(:call).and_wrap_original do |original, **kwargs|
        kwargs[:trip].id == trip.id ? Result.fail(:companion_not_allowed) : original.call(**kwargs)
      end
      logged = []
      allow(Rails.logger).to receive(:error) { |message| logged << message }
      result = described_class.call(series: series, today: monday)
      expect(trip.transport_trip_stops.reload.map(&:label)).to eq([ "Praça Central", dest.name ])
      expect(result).to eq(added: 8, created_trips: 8, pending: 0, failed: 1)
      expect(logged).to eq([ "[Transport::MaterializeSeries] series=#{series.id} date=#{monday.iso8601} failed: Transport::MaterializeSeries::Refused" ])
    end

    it "paciente já na viagem por outra origem: não entra de novo e não ganha parada nova" do
      trip = trip!(date: monday, departure: "05:30", destination: dest)
      passenger!(trip, patient: patient)
      described_class.call(series: one_day, today: monday)
      expect(trip.transport_trip_stops.reload.count).to eq(2)
      expect(trip.transport_trip_passengers.count).to eq(1)
    end

    it "falha no meio de um dia desfaz as escritas desse dia (viagem e paradas criadas), e só dele" do
      wednesday = monday + 2
      allow(Transport::AddPassenger).to receive(:call).and_wrap_original do |original, **kwargs|
        raise ActiveRecord::StatementInvalid, "boom" if kwargs[:trip].date == wednesday

        original.call(**kwargs)
      end
      stops_before = TransportTripStop.count
      result = described_class.call(series: series, today: monday)
      expect(result).to include(failed: 1, created_trips: 8, added: 8)
      expect(TransportTrip.where(date: wednesday).count).to eq(0)
      expect(TransportTrip.where(transport_series_id: series.id).count).to eq(8)
      expect(TransportTripStop.count - stops_before).to eq(16)
    end
  end
end
