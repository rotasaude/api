require "rails_helper"

# Módulo 30, Task 8 (ADR 0048; plano, Desvio 9; §14 T18, T23; Review Focus 5):
# a central corrige a presença de viagem `done` com motivo; uma linha de
# transport_attendance_corrections por campo mudado, tudo ou nada, sob o
# trigger (TransportTripPassenger.with_attendance_correction). Correção de
# passageiro com trecho de frota do TFD já feito → tfd_leg_done (a linha do
# BPA já existe); passageiro anonimizado → passenger_anonymized.
RSpec.describe Transport::CorrectAttendance do
  let!(:city) { transport_city!(tfd: true) }
  let(:central) { dispatcher! }
  let(:trip) { trip!(date: Date.current - 1, vehicle: vehicle!, driver: driver_user!.transport_driver, status: "done") }
  let(:reason) { "Motorista marcou o paciente errado na lista" }

  def correct(items, why: reason, on: trip) = described_class.call(trip: on, items: items, reason: why, by: central)

  # Passageiro de TFD (origin: "tfd") do processo do paciente, com o trecho de
  # frota gravado direto (os comandos do trecho são das Tasks 9–11).
  def tfd_rider!(leg_done:)
    patient = transport_patient!
    tfd = tfd_case!(status: "travelling", patient: patient)
    rider = passenger!(trip, patient: patient, origin: "tfd", tfd_case: tfd, exception_reason: nil, attendance: "boarded")
    TfdLeg.create!(tfd_case: tfd, direction: "outbound", mode: "fleet", date: trip.date, distance_km: 380, transport_trip_passenger: rider,
                   created_by_user: central, done_at: (Time.current if leg_done))
    rider
  end

  it "Review Focus 5: sem trecho de TFD, boarded → no_show grava a correção e muda a presença sob o trigger" do
    rider = passenger!(trip, attendance: "boarded")
    expect { rider.update!(attendance: "no_show") }.to raise_error(ActiveRecord::StatementInvalid, /attendance is frozen/)
    rider.reload

    result = correct([ { "passenger_id" => rider.id, "attendance" => "no_show" } ])

    expect(result).to be_ok
    expect(rider.reload.attendance).to eq("no_show")
    correction = TransportAttendanceCorrection.find_by!(transport_trip_passenger: rider)
    expect(correction).to have_attributes(field: "attendance", from_value: "boarded", to_value: "no_show", by_user_id: central.id,
                                          reason: reason)
    # A trava volta depois da correção (o SET LOCAL não vaza para o resto da transação).
    expect { rider.update!(attendance: "boarded") }.to raise_error(ActiveRecord::StatementInvalid, /attendance is frozen/)
  end

  it "Review Focus 5: trecho de frota do TFD já feito → tfd_leg_done; presença e correções intactas" do
    rider = tfd_rider!(leg_done: true)
    plain = passenger!(trip, attendance: "boarded")

    result = correct([ { "passenger_id" => plain.id, "attendance" => "no_show" }, { "passenger_id" => rider.id, "attendance" => "no_show" } ])

    expect(result).to be_failure
    expect(result.reason).to eq(:tfd_leg_done)
    expect(result.details[:path]).to eq("items.1.attendance")
    expect(rider.reload.attendance).to eq("boarded")
    expect(plain.reload.attendance).to eq("boarded")
    expect(TransportAttendanceCorrection.count).to eq(0)
  end

  it "trecho de frota ainda não feito: boarded → no_show corrige normalmente" do
    rider = tfd_rider!(leg_done: false)
    expect(correct([ { "passenger_id" => rider.id, "attendance" => "no_show" } ])).to be_ok
    expect(rider.reload.attendance).to eq("no_show")
  end

  it "no_show → boarded com trecho de frota aberto chama Tfd::FleetLegs.complete_passenger!" do
    rider = tfd_rider!(leg_done: false)
    rider.reload
    TransportTripPassenger.with_attendance_correction { rider.update!(attendance: "no_show") }
    expect(Tfd::FleetLegs).to receive(:complete_passenger!).with(rider, by: central).and_call_original
    expect(correct([ { "passenger_id" => rider.id, "attendance" => "boarded" } ])).to be_ok
    expect(rider.reload.attendance).to eq("boarded")
  end

  it "uma linha por campo mudado (paciente e acompanhante) e publica transport.attendance_corrected só com ids" do
    rider = passenger!(trip, attendance: "boarded", companion_name: "Filha do Paciente", companion_attendance: "boarded")
    same = passenger!(trip, attendance: "no_show")

    expect do
      result = correct([ { "passenger_id" => rider.id, "attendance" => "no_show", "companion_attendance" => "no_show" },
                         { "passenger_id" => same.id, "attendance" => "no_show" } ])
      expect(result).to be_ok
    end.to change { DomainEvent.where(name: "transport.attendance_corrected").count }.by(1)

    rows = TransportAttendanceCorrection.where(transport_trip_passenger: rider).pluck(:field, :from_value, :to_value)
    expect(rows).to contain_exactly(%w[attendance boarded no_show], %w[companion_attendance boarded no_show])
    expect(TransportAttendanceCorrection.where(transport_trip_passenger: same)).to be_empty
    payloads = DomainEvent.where(name: "transport.attendance_corrected").map(&:payload)
    expect(payloads).to include({ "trip_id" => trip.id, "passenger_ids" => [ rider.id ] })
  end

  it "motivo com 9 caracteres → invalid_request; nada muda" do
    rider = passenger!(trip, attendance: "boarded")
    result = correct([ { "passenger_id" => rider.id, "attendance" => "no_show" } ], why: "123456789")
    expect(result.reason).to eq(:invalid_request)
    expect(result.details[:path]).to eq("reason")
    expect(rider.reload.attendance).to eq("boarded")
    expect(TransportAttendanceCorrection.count).to eq(0)
  end

  it "passageiro anonimizado → passenger_anonymized (nunca 500)" do
    rider = passenger!(trip, attendance: "boarded")
    rider.update!(anonymized_at: Time.current)
    result = correct([ { "passenger_id" => rider.id, "attendance" => "no_show" } ])
    expect(result.reason).to eq(:passenger_anonymized)
    expect(rider.reload.attendance).to eq("boarded")
  end

  it "só em viagem done; pending como destino e acompanhante inexistente → invalid_request; de outra viagem → not_found" do
    open_trip = trip!(date: Date.current, vehicle: vehicle!, driver: driver_user!.transport_driver, status: "in_progress")
    open_rider = passenger!(open_trip)
    expect(correct([ { "passenger_id" => open_rider.id, "attendance" => "no_show" } ], on: open_trip).reason).to eq(:invalid_transition)

    rider = passenger!(trip, attendance: "boarded")
    expect(correct([ { "passenger_id" => rider.id, "attendance" => "pending" } ]).details[:path]).to eq("items.0.attendance")
    result = correct([ { "passenger_id" => rider.id, "attendance" => "boarded", "companion_attendance" => "no_show" } ])
    expect(result.details[:path]).to eq("items.0.companion_attendance")
    expect(correct([ { "passenger_id" => open_rider.id, "attendance" => "no_show" } ]).reason).to eq(:not_found)
    expect(TransportAttendanceCorrection.count).to eq(0)
  end
end
