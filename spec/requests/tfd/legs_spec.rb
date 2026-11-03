require "rails_helper"

# Módulo 30, Task 11 (ADR 0048; contrato §6; §14 T8, T10, T11; plano, Desvios
# 13–14): trechos do TFD pela comissão — frota ligada ao passageiro da viagem
# (feito no fechamento da viagem, com o paciente `boarded`) e passagem (feito
# por POST /tfd/legs/:id/done); toda escrita devolve o <tfd-case> inteiro;
# GET /tfd/cases/:id/allowances soma a ajuda de custo.
RSpec.describe "TFD — trechos e ajuda de custo", type: :request do
  let!(:city) { transport_city!(tfd: true, billing: true) }
  let(:committee) { committee! }
  let(:patient) { transport_patient! }
  let(:tfd) { tfd_case!(status: "authorized", patient: patient) }
  let(:ticket) { { amount_cents: 15_000, carrier: "Viação Garcia" } }

  def add_leg(body = {}, case_id: tfd.id, **fields) = json_post("/tfd/cases/#{case_id}/legs", body.merge(fields))
  def done(leg_id) = json_post("/tfd/legs/#{leg_id}/done")
  def errors = json_body["problems"].map { |p| p["error"] }

  # Viagem de hoje confirmada com o paciente do TFD (origin tfd, deste processo) e o acompanhante.
  def tfd_trip!(driver_user)
    trip = trip!(date: Date.current, vehicle: vehicle!, driver: driver_user.transport_driver, status: "confirmed")
    rider = passenger!(trip, patient: patient, origin: "tfd", tfd_case: tfd, exception_reason: nil,
                             companion_name: "Filha do Paciente", companion_attendance: "pending")
    [ trip, rider ]
  end

  before { sign_in_as(committee) }

  it "passagem: registra (authorized → scheduled), marca feito (→ travelling) e devolve o <tfd-case>; de novo → tfd_leg_done" do
    add_leg(direction: "outbound", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket, companion: true)
    expect(response).to have_http_status(:ok)
    expect(json_body.keys).to include("id", "patient", "report", "legs", "allowances", "events", "trip_passengers")
    expect(json_body["status"]).to eq("scheduled")
    leg = json_body["legs"].sole
    expect(leg).to include("direction" => "outbound", "mode" => "bus_ticket", "distance_km" => 380, "companion" => true,
                           "outbound_leg_id" => nil, "trip_passenger_id" => nil, "done" => false,
                           "ticket" => { "amount_cents" => 15_000, "carrier" => "Viação Garcia" })

    done(leg["id"])
    expect(response).to have_http_status(:ok)
    expect(json_body["status"]).to eq("travelling")
    expect(json_body["legs"].sole["done"]).to be(true)
    expect(json_body["allowances"].map { |a| [ a["person"], a["kind"], a["quantity"] ] })
      .to contain_exactly([ "patient", "ground_km", 8 ], [ "companion", "ground_km", 8 ])

    expect { done(leg["id"]) }.not_to change(TfdAllowance, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["error"]).to eq("tfd_leg_done")
  end

  it "Task 13 I1: volta mais de 999 noites depois da ida → invalid_request em date (a alimentação no BPA vai até 999); 999 aceita" do
    outbound_on = Date.current - 1000
    add_leg(direction: "outbound", mode: "bus_ticket", date: outbound_on.iso8601, ticket: ticket)
    expect(response).to have_http_status(:ok)
    add_leg(direction: "return", mode: "bus_ticket", date: (outbound_on + 1000).iso8601, ticket: ticket)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "invalid_request", "path" => "date")
    expect(TfdLeg.where(direction: "return")).to be_empty

    add_leg(direction: "return", mode: "bus_ticket", date: (outbound_on + 999).iso8601, ticket: ticket)
    expect(response).to have_http_status(:ok)
    expect(TfdLeg.find_by!(direction: "return").outbound_leg.date).to eq(outbound_on)
  end

  it "recusas de forma todas de uma vez; volta sem ida → no_outbound_leg; acompanhante sem indicação → companion_not_allowed" do
    add_leg(direction: "sideways", mode: "boat", date: "2026-02-30", extra: 1)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["problems"].map { |p| p["path"] }).to include("direction", "mode", "date", "extra")

    add_leg(direction: "outbound", mode: "bus_ticket", date: Date.current.iso8601, ticket: { amount_cents: 0, carrier: "" })
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly("ticket.amount_cents", "ticket.carrier")

    add_leg(direction: "outbound", mode: "fleet", date: Date.current.iso8601, ticket: ticket, companion: true)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly("trip_passenger_id", "ticket", "companion")

    add_leg(direction: "return", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "no_outbound_leg")

    alone = tfd_case!(status: "authorized", report: { "companion_indicated" => false, "companion_reason" => nil })
    add_leg({ direction: "outbound", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket, companion: true }, case_id: alone.id)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "companion_not_allowed", "path" => "companion")
    expect(TfdLeg.count).to eq(0)
    expect(tfd.reload.status).to eq("authorized")
  end

  it "frota com passageiro de outro paciente ou sem o tfd_case_id deste processo → invalid_request trip_passenger_id" do
    trip = trip!(date: Date.current, vehicle: vehicle!, driver: driver_user!.transport_driver, status: "confirmed")
    stranger = passenger!(trip)
    plain = passenger!(trip, patient: patient)
    [ stranger, plain, SecureRandom.uuid ].each do |rider|
      add_leg(direction: "outbound", mode: "fleet", date: Date.current.iso8601, trip_passenger_id: rider.is_a?(String) ? rider : rider.id)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "invalid_request", "path" => "trip_passenger_id")
    end
    expect(TfdLeg.count).to eq(0)
  end

  it "o fechamento da viagem com o paciente boarded marca o trecho de frota feito e cria ground_km só do paciente (acompanhante faltou)" do
    davi = driver_user!
    trip, rider = tfd_trip!(davi)
    add_leg(direction: "outbound", mode: "fleet", date: Date.current.iso8601, trip_passenger_id: rider.id)
    expect(response).to have_http_status(:ok)
    leg = TfdLeg.find(json_body["legs"].sole["id"])
    expect(leg).to have_attributes(transport_trip_passenger_id: rider.id, companion: false, ticket_amount_cents: nil)

    done(leg.id)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["error"]).to eq("fleet_leg_by_trip")
    expect(leg.reload.done_at).to be_nil

    sign_in_as(davi)
    json_post("/transport/my_trips/#{trip.id}/start")
    json_post("/transport/my_trips/#{trip.id}/attendance",
              items: [ { passenger_id: rider.id, attendance: "boarded", companion_attendance: "no_show" } ])
    json_post("/transport/my_trips/#{trip.id}/close", odometer_start: 1000, odometer_end: 1760, fuel: [], expenses: [])
    expect(response).to have_http_status(:ok)

    expect(leg.reload.done_at).to be_present
    expect(TfdAllowance.where(tfd_leg: leg).pluck(:person, :kind, :quantity)).to eq([ [ "patient", "ground_km", 8 ] ])
    expect(tfd.reload.status).to eq("travelling")
    expect(tfd.tfd_case_events.find_by!(kind: "travelling").by_user_id).to eq(davi.id)
    expect(DomainEvent.where(name: "tfd.leg_done").map(&:payload)).to eq([ { "tfd_leg_id" => leg.id } ])

    # A correção da central depois do trecho feito é recusada (Task 8, Review Focus 5).
    corrected = Transport::CorrectAttendance.call(trip: trip.reload, items: [ { "passenger_id" => rider.id, "attendance" => "no_show" } ],
                                                  reason: "Motorista marcou o paciente errado", by: dispatcher!)
    expect(corrected.reason).to eq(:tfd_leg_done)
  end

  it "o paciente que faltou não tem o trecho feito; a correção no_show → boarded o completa com o deslocamento" do
    davi = driver_user!
    trip, rider = tfd_trip!(davi)
    add_leg(direction: "outbound", mode: "fleet", date: Date.current.iso8601, trip_passenger_id: rider.id)
    leg = TfdLeg.find(json_body["legs"].sole["id"])
    sign_in_as(davi)
    json_post("/transport/my_trips/#{trip.id}/start")
    json_post("/transport/my_trips/#{trip.id}/attendance",
              items: [ { passenger_id: rider.id, attendance: "no_show", companion_attendance: "no_show" } ])
    json_post("/transport/my_trips/#{trip.id}/close", odometer_start: 1000, odometer_end: 1760, fuel: [], expenses: [])
    expect(leg.reload.done_at).to be_nil
    expect(TfdAllowance.count).to eq(0)

    central = dispatcher!
    corrected = Transport::CorrectAttendance.call(trip: trip.reload, items: [ { "passenger_id" => rider.id, "attendance" => "boarded" } ],
                                                  reason: "Paciente embarcou e o motorista errou", by: central)
    expect(corrected).to be_ok
    expect(leg.reload.done_at).to be_present
    expect(TfdAllowance.where(tfd_leg: leg).pluck(:person, :kind)).to eq([ %w[patient ground_km] ])
    expect(tfd.reload.tfd_case_events.find_by!(kind: "travelling").by_user_id).to eq(central.id)
  end

  it "trecho de frota registrado depois do fechamento, com o paciente boarded, nasce feito" do
    davi = driver_user!
    trip, rider = tfd_trip!(davi)
    sign_in_as(davi)
    json_post("/transport/my_trips/#{trip.id}/start")
    json_post("/transport/my_trips/#{trip.id}/attendance",
              items: [ { passenger_id: rider.id, attendance: "boarded", companion_attendance: "boarded" } ])
    json_post("/transport/my_trips/#{trip.id}/close", odometer_start: 1000, odometer_end: 1760, fuel: [], expenses: [])

    sign_in_as(committee)
    add_leg(direction: "outbound", mode: "fleet", date: Date.current.iso8601, trip_passenger_id: rider.id)
    expect(response).to have_http_status(:ok)
    expect(json_body["status"]).to eq("travelling")
    expect(json_body["legs"].sole["done"]).to be(true)
    expect(json_body["allowances"].map { |a| [ a["person"], a["kind"] ] }).to contain_exactly(%w[patient ground_km], %w[companion ground_km])

    add_leg(direction: "outbound", mode: "fleet", date: Date.current.iso8601, trip_passenger_id: rider.id)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "invalid_request", "path" => "trip_passenger_id") # uma ida por passageiro
  end

  it "GET /tfd/cases/:id/allowances soma total_cents; sem dado do paciente" do
    add_leg(direction: "outbound", mode: "bus_ticket", date: (Date.current - 2).iso8601, ticket: ticket, companion: true)
    out_id = json_body["legs"].sole["id"]
    done(out_id)
    add_leg(direction: "return", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket, companion: true)
    back = json_body["legs"].find { |l| l["direction"] == "return" }
    expect(back["outbound_leg_id"]).to eq(out_id)
    done(back["id"])

    get "/tfd/cases/#{tfd.id}/allowances"
    expect(response).to have_http_status(:ok)
    # ida e volta: 2 × (495 × 8) + 2 × (1000 × 8); volta: 2 noites — paciente 1000 × 2, acompanhante 2475 × 2.
    expect(json_body["total_cents"]).to eq((2 * 3960) + (2 * 8000) + 2000 + 4950)
    expect(json_body["total_cents"]).to eq(json_body["items"].sum { |i| i["total_cents"] })
    expect(json_body["items"].size).to eq(6)
    expect(json_body["items"].first.keys)
      .to contain_exactly("id", "person", "kind", "sigtap_code", "quantity", "table_cents", "complement_cents", "total_cents")
    expect(response.body).not_to include(patient.display_name)
  end

  it "só a comissão; rascunho e trecho desconhecido → 404; processo fora de authorized/scheduled/travelling → invalid_transition" do
    sign_in_as(dispatcher!)
    add_leg(direction: "outbound", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket)
    expect(response).to have_http_status(:forbidden)
    get "/tfd/cases/#{tfd.id}/allowances"
    expect(response).to have_http_status(:forbidden)

    sign_in_as(committee)
    draft = tfd_case!(status: "draft")
    add_leg({ direction: "outbound", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket }, case_id: draft.id)
    expect(response).to have_http_status(:not_found)
    get "/tfd/cases/#{draft.id}/allowances"
    expect(response).to have_http_status(:not_found)
    done(SecureRandom.uuid)
    expect(response).to have_http_status(:not_found)

    submitted = tfd_case!(status: "submitted")
    add_leg({ direction: "outbound", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket }, case_id: submitted.id)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["error"]).to eq("invalid_transition")
  end

  it "tfd desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: "tfd", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    add_leg(direction: "outbound", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to include("error" => "feature_disabled", "feature" => "tfd")
  end

  it "van de ida e volta no mesmo dia, numa viagem só: ida e volta de frota na mesma linha → deslocamento dos dois sentidos e meal_day" do
    davi = driver_user!
    trip, rider = tfd_trip!(davi)
    add_leg(direction: "outbound", mode: "fleet", date: Date.current.iso8601, trip_passenger_id: rider.id)
    expect(response).to have_http_status(:ok)
    add_leg(direction: "return", mode: "fleet", date: (Date.current + 1).iso8601, trip_passenger_id: rider.id)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "invalid_request", "path" => "date") # a volta é no dia local do return_at
    add_leg(direction: "return", mode: "fleet", date: trip.return_at.in_time_zone.to_date.iso8601, trip_passenger_id: rider.id)
    expect(response).to have_http_status(:ok)
    legs = TfdLeg.where(transport_trip_passenger_id: rider.id).order(:direction).to_a
    expect(legs.map(&:direction)).to eq(%w[outbound return])
    expect(legs.last.outbound_leg_id).to eq(legs.first.id)

    sign_in_as(davi)
    json_post("/transport/my_trips/#{trip.id}/start")
    json_post("/transport/my_trips/#{trip.id}/attendance",
              items: [ { passenger_id: rider.id, attendance: "boarded", companion_attendance: "boarded" } ])
    json_post("/transport/my_trips/#{trip.id}/close", odometer_start: 1000, odometer_end: 1760, fuel: [], expenses: [])
    expect(response).to have_http_status(:ok)

    expect(legs.map { |l| l.reload.done? }).to eq([ true, true ])
    rows = TfdAllowance.where(tfd_case: tfd).pluck(:tfd_leg_id, :person, :kind, :quantity)
    expect(rows).to contain_exactly([ legs[0].id, "patient", "ground_km", 8 ], [ legs[0].id, "companion", "ground_km", 8 ],
                                    [ legs[1].id, "patient", "ground_km", 8 ], [ legs[1].id, "companion", "ground_km", 8 ],
                                    [ legs[1].id, "patient", "meal_day", 1 ], [ legs[1].id, "companion", "meal_day", 1 ])
    expect(DomainEvent.where(name: "tfd.allowances_calculated").map(&:payload)).to eq([ { "tfd_case_id" => tfd.id, "tfd_leg_id" => legs[1].id } ])
  end

  it "viagem dividida (T38): ida na viagem A, volta na viagem B → deslocamento das duas e a alimentação só quando as duas estão feitas" do
    trip_a = trip!(date: Date.current - 3, vehicle: vehicle!, driver: driver_user!.transport_driver, status: "done")
    rider_a = passenger!(trip_a, patient: patient, origin: "tfd", tfd_case: tfd, exception_reason: nil, attendance: "boarded",
                                 companion_name: "Filha do Paciente", companion_attendance: "boarded")
    add_leg(direction: "outbound", mode: "fleet", date: trip_a.date.iso8601, trip_passenger_id: rider_a.id)
    expect(response).to have_http_status(:ok)
    expect(json_body["status"]).to eq("travelling") # viagem A já fechada com o paciente boarded: a ida nasce feita
    expect(TfdAllowance.where(kind: %w[meal_day meal_overnight])).to be_empty

    davi = driver_user!
    trip_b, rider_b = tfd_trip!(davi)
    add_leg(direction: "return", mode: "fleet", date: Date.current.iso8601, trip_passenger_id: rider_b.id)
    expect(response).to have_http_status(:ok)
    back = TfdLeg.find_by!(transport_trip_passenger_id: rider_b.id)
    expect(back.outbound_leg.transport_trip_passenger_id).to eq(rider_a.id)
    expect(TfdAllowance.where(kind: %w[meal_day meal_overnight])).to be_empty

    sign_in_as(davi)
    json_post("/transport/my_trips/#{trip_b.id}/start")
    json_post("/transport/my_trips/#{trip_b.id}/attendance",
              items: [ { passenger_id: rider_b.id, attendance: "boarded", companion_attendance: "boarded" } ])
    json_post("/transport/my_trips/#{trip_b.id}/close", odometer_start: 1000, odometer_end: 1760, fuel: [], expenses: [])
    expect(response).to have_http_status(:ok)

    expect(TfdAllowance.where(kind: "ground_km").pluck(:tfd_leg_id).tally).to eq(back.outbound_leg_id => 2, back.id => 2)
    expect(TfdAllowance.where(kind: %w[meal_day meal_overnight]).pluck(:tfd_leg_id, :person, :kind, :quantity))
      .to contain_exactly([ back.id, "patient", "meal_overnight", 3 ], [ back.id, "companion", "meal_overnight", 3 ])
  end

  it "passagem com data futura → 422 leg_in_future" do
    add_leg(direction: "outbound", mode: "bus_ticket", date: (Date.current + 1).iso8601, ticket: ticket)
    done(json_body["legs"].sole["id"])
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to include("error" => "leg_in_future", "path" => "date")
  end
end
