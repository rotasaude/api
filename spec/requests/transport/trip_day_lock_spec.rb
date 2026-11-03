require "rails_helper"

# Módulo 30, revisão final I2 (ADR 0048): o dia local da viagem não muda
# depois que um trecho de frota do TFD ou um passageiro de série se prendeu a
# ele (422 trip_day_locked); a hora no mesmo dia muda.
RSpec.describe "Transporte — dia da viagem preso", type: :request do
  let!(:city) { transport_city!(tfd: true) }
  let(:day) { Date.current + 2 }
  let(:trip) { trip!(date: day, vehicle: vehicle!(seats: 15), driver: driver_user!(category: "D").transport_driver, status: "confirmed") }
  let(:patient) { transport_patient! }

  def at(date, hhmm) = Time.zone.parse("#{date.iso8601} #{hhmm}").iso8601
  def move(departure, back) = json_patch("/transport/trips/#{trip.id}", departure_at: departure, return_at: back)

  def fleet_leg!(direction)
    tfd = tfd_case!(status: "authorized", patient: patient)
    rider = passenger!(trip, patient: patient, origin: "tfd", tfd_case: tfd, exception_reason: nil)
    date = direction == "return" ? trip.return_at.in_time_zone.to_date : trip.date
    added = Tfd::AddLeg.call(tfd_case: tfd, by: committee!,
                             attrs: { "direction" => "outbound", "mode" => "fleet", "date" => trip.date.iso8601, "trip_passenger_id" => rider.id })
    raise "ida recusada: #{added.reason}" if added.failure?
    if direction == "return"
      back = Tfd::AddLeg.call(tfd_case: tfd.reload, by: committee!,
                              attrs: { "direction" => "return", "mode" => "fleet", "date" => date.iso8601, "trip_passenger_id" => rider.id })
      raise "volta recusada: #{back.reason}" if back.failure?
    end
    rider
  end

  before { sign_in_as(dispatcher!) }

  it "passageiro de série: outro dia → 422 trip_day_locked em date; outra hora no mesmo dia → 200" do
    series = Transport::SaveSeries.call(by: dispatcher!, attrs: {
      "patient_id" => patient.id, "destination_id" => destination!.id, "weekdays" => [ 1, 2, 3, 4, 5, 6, 7 ],
      "appointment_time" => "09:00", "departure_time" => "07:00", "return_time" => "18:00",
      "boarding_label" => "Praça Central", "starts_on" => day.iso8601, "wheelchair" => false
    }).payload.fetch(:series)
    passenger!(trip, patient: patient, origin: "series", transport_series: series, exception_reason: nil)

    move(at(day + 1, "07:00"), at(day + 1, "18:00"))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "trip_day_locked", "path" => "date")
    expect(trip.reload.date).to eq(day)

    move(at(day, "08:30"), at(day, "19:00"))
    expect(response).to have_http_status(:ok)
    expect(trip.reload.departure_at.in_time_zone.strftime("%H:%M")).to eq("08:30")
  end

  it "trecho de frota do TFD: outro dia → trip_day_locked; anulado (passageiro retirado), o dia muda" do
    rider = fleet_leg!("outbound")
    move(at(day - 1, "07:00"), at(day - 1, "18:00"))
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "trip_day_locked", "date" ])

    expect(Transport::RemovePassenger.call(passenger: rider, reason: "Paciente remarcou a viagem", by: dispatcher!)).to be_ok
    move(at(day - 1, "07:00"), at(day - 1, "18:00"))
    expect(response).to have_http_status(:ok)
    expect(trip.reload.date).to eq(day - 1)
  end

  it "trecho de VOLTA de frota: a chegada não vai a outro dia (trip_day_locked em return_at); a mesma chegada mais tarde vale" do
    fleet_leg!("return")
    move(at(day, "07:00"), at(day + 1, "06:00"))
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "trip_day_locked", "return_at" ])
    move(at(day, "07:00"), at(day, "21:00"))
    expect(response).to have_http_status(:ok)
  end

  it "sem trecho nem série, o dia muda" do
    passenger!(trip, patient: patient)
    move(at(day + 1, "07:00"), at(day + 1, "18:00"))
    expect(response).to have_http_status(:ok)
    expect(trip.reload.date).to eq(day + 1)
  end
end
