require "rails_helper"

# Módulo 30, Task 16 (ADR 0048; contrato §9, §14 T16): painel do transporte e
# do TFD. Só números, sem trilha; contagens de 1 a 4 saem "lt5"; somas não.
RSpec.describe "Transporte — painel", type: :request do
  let!(:city) { transport_city!(tfd: true) }
  let(:month) { Time.zone.today.strftime("%Y-%m") }
  let(:day) { Time.zone.today.beginning_of_month + 9 }

  # Viagem done do mês: `riders` passageiros (os `no_shows` primeiros faltam) e,
  # se pedido, o diário de bordo.
  def done_trip(riders:, no_shows: 0, on: day, km: nil, fuel: [], seats: 15, origin: {})
    trip = trip!(date: on, vehicle: vehicle!(seats: seats), driver: driver_user!.transport_driver, status: "in_progress")
    riders.times do |index|
      passenger!(trip, **origin).update!(attendance: index < no_shows ? "no_show" : "boarded")
    end
    trip.update!(status: "done")
    if km
      TransportTripLog.create!(transport_trip: trip, odometer_start: 1000, odometer_end: 1000 + km, fuel: fuel, expenses: [],
                               closed_at: Time.current, closed_by_user: trip.transport_driver.user)
    end
    trip
  end

  describe "GET /transport/dashboard" do
    before { sign_in_as(dispatcher!) }

    it "duas viagens done (10 e 5 de 15 lugares) → trips lt5, ocupação 50, km e combustível somados, 6 faltas" do
      done_trip(riders: 10, no_shows: 6, km: 240, fuel: [ { "liters" => 30, "amount_cents" => 15_000, "station" => "Posto A" } ])
      done_trip(riders: 5, km: 100, fuel: [ { "liters" => 20, "amount_cents" => 10_000, "station" => "Posto B" } ])

      get "/transport/dashboard", params: { month: month }

      expect(response).to have_http_status(:ok)
      expect(json_body).to include("month" => month, "trips" => "lt5", "occupancy_pct" => 50, "no_shows" => 6, "km" => 340,
                                   "fuel_cents" => 25_000, "tfd_paid_cents" => 0)
      expect(json_body.fetch("exceptions")).to eq(15)
    end

    it "viagem fora do mês, não done e passageiro retirado não entram; 0 fica 0 e sem viagem não há ocupação" do
      done_trip(riders: 2, on: day.prev_month.beginning_of_month + 3, km: 50)
      done_trip(riders: 1).tap do |trip|
        trip.transport_trip_passengers.first.update!(removed_at: Time.current, removed_by_user: dispatcher!, remove_reason: "Desistiu")
      end
      trip!(date: day, vehicle: vehicle!, driver: driver_user!.transport_driver, status: "confirmed")

      get "/transport/dashboard", params: { month: month }

      expect(json_body).to include("trips" => "lt5", "no_shows" => 0, "exceptions" => 0, "km" => 0, "fuel_cents" => 0, "occupancy_pct" => 0)

      get "/transport/dashboard", params: { month: day.next_month.strftime("%Y-%m") }
      expect(json_body).to include("trips" => 0, "no_shows" => 0, "occupancy_pct" => nil, "km" => 0, "tfd_by_status" => {})
    end

    it "5 viagens aparecem como número; 1 a 4 faltas viram lt5, 5 faltas ficam 5" do
      4.times { done_trip(riders: 1, no_shows: 1) }
      get "/transport/dashboard", params: { month: month }
      expect(json_body).to include("trips" => "lt5", "no_shows" => "lt5", "exceptions" => "lt5")

      done_trip(riders: 1, no_shows: 1)
      get "/transport/dashboard", params: { month: month }
      expect(json_body).to include("trips" => 5, "no_shows" => 5, "exceptions" => 5)
    end

    it "viagem do último dia do mês conta nesse mês, não no seguinte" do
      last = Time.zone.today.end_of_month
      trip = done_trip(riders: 1, on: last)
      expect(trip.date).to eq(last)

      get "/transport/dashboard", params: { month: last.next_day.strftime("%Y-%m") }
      expect(json_body.fetch("trips")).to eq(0)
      get "/transport/dashboard", params: { month: last.strftime("%Y-%m") }
      expect(json_body.fetch("trips")).to eq("lt5")
    end

    it "TFD: processos do mês por situação atual (1..4 lt5), pagamentos do mês somados sem supressão" do
      authorized = tfd_case!(status: "authorized")
      tfd_case!(status: "authorized")
      tfd_case!(status: "draft")
      [ [ authorized, Time.zone.today, 30_000 ], [ authorized, Time.zone.today, 12_500 ], [ authorized, Time.zone.today.prev_month.beginning_of_month, 99_999 ] ].each do |tfd, on, cents|
        TfdPayment.create!(tfd_case: tfd, by_user: committee!, paid_on: on, amount_cents: cents, payment_method: "pix", receipt_number: "R#{cents}")
      end
      old = tfd_case!(status: "submitted")
      old.update_columns(created_at: Time.zone.today.prev_month.beginning_of_month + 2.days)

      get "/transport/dashboard", params: { month: month }

      expect(json_body.fetch("tfd_by_status")).to eq("authorized" => "lt5", "draft" => "lt5")
      expect(json_body.fetch("tfd_paid_cents")).to eq(42_500)
    end

    it "sem o TFD ligado, tfd_by_status é {}" do
      tfd_case!(status: "authorized")
      Platform::Features.set!(city: city, key: "tfd", enabled: false, maintainer: ledi_maintainer!)

      get "/transport/dashboard", params: { month: month }

      expect(response).to have_http_status(:ok)
      expect(json_body.fetch("tfd_by_status")).to eq({})
    end

    it "sem month usa o mês corrente; month inválido ou query estranha → 422 com path" do
      get "/transport/dashboard"
      expect(response).to have_http_status(:ok)
      expect(json_body.fetch("month")).to eq(month)

      [ "2026-13", "2026-1", "abril", "1999-05", "" ].each do |bad|
        get "/transport/dashboard", params: { month: bad }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_body).to include("error" => "invalid_request", "path" => "month")
      end
      get "/transport/dashboard", params: { month: month, name: "x" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["path"]).to eq("name")
    end

    it "não leva nome, CPF nem destino de tratamento" do
      trip = done_trip(riders: 1, km: 10)
      patient = trip.transport_trip_passengers.first.patient
      tfd_case!(status: "authorized", patient: patient)

      get "/transport/dashboard", params: { month: month }

      expect(response.body).not_to include(patient.display_name.to_s, "Ponta Grossa", "Londrina")
      expect(json_body.keys).to match_array(%w[month trips occupancy_pct no_shows km fuel_cents tfd_by_status tfd_paid_cents exceptions])
    end
  end

  it "admin, central e comissão leem; motorista → 403" do
    [ transport_admin!, dispatcher!, committee! ].each do |user|
      sign_in_as(user)
      get "/transport/dashboard", params: { month: month }
      expect(response).to have_http_status(:ok)
    end
    sign_in_as(driver_user!)
    get "/transport/dashboard", params: { month: month }
    expect(response).to have_http_status(:forbidden)
  end

  it "não grava trilha de acesso ao prontuário" do
    sign_in_as(dispatcher!)
    done_trip(riders: 1)
    expect { get "/transport/dashboard", params: { month: month } }.not_to change { DomainEvent.where(name: "clinical_record.viewed").count }
  end
end
