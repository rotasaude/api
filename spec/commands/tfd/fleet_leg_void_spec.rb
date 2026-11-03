require "rails_helper"

# Módulo 30, revisão final I1 e FW8 (ADR 0048): o trecho de frota do TFD não
# fica aberto para sempre. A retirada do passageiro, o cancelamento da viagem
# e a falta do paciente no fechamento anulam os trechos abertos daquela linha;
# o anulado não segura a prestação de contas, não pareia com a volta e não
# gera ajuda de custo. A volta de frota pareia primeiro com a ida da mesma
# linha (FW8).
RSpec.describe "TFD — trecho de frota anulado" do
  include ActiveJob::TestHelper

  let!(:city) { transport_city!(tfd: true, billing: true) }
  let(:committee) { committee! }
  let(:patient) { transport_patient! }
  let(:tfd) { tfd_case!(status: "authorized", patient: patient) }
  let(:ticket) { { "amount_cents" => 15_000, "carrier" => "Viação Garcia" } }
  let(:png) { "\x89PNG\r\n\x1A\n".b + "comprovante".b }
  let(:proof) { { "content_type" => "image/png", "data" => Base64.strict_encode64(png) } }

  before { TransportSetting.current.update!(tfd_billing_health_unit: health_management_unit!) }

  def add_leg!(**fields)
    result = Tfd::AddLeg.call(tfd_case: tfd.reload, attrs: fields.transform_keys(&:to_s), by: committee)
    raise "AddLeg recusou: #{result.reason} #{result.details}" if result.failure?

    result.payload.fetch(:leg)
  end

  def confirmed_trip!(date: Date.current, driver: driver_user!)
    trip!(date: date, vehicle: vehicle!, driver: driver.transport_driver, status: "confirmed")
  end

  def tfd_rider!(trip) = passenger!(trip, patient: patient, origin: "tfd", tfd_case: tfd, exception_reason: nil)

  def fleet_outbound!(trip)
    rider = tfd_rider!(trip)
    [ rider, add_leg!(direction: "outbound", mode: "fleet", date: trip.date.iso8601, trip_passenger_id: rider.id) ]
  end

  # Ida e volta de passagem feitas (o processo vai a travelling) e a prestação de contas.
  def ticket_pair_and_close!
    out = add_leg!(direction: "outbound", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket)
    expect(Tfd::CompleteLeg.call(leg: out, by: committee)).to be_ok
    back = add_leg!(direction: "return", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket)
    expect(back.outbound_leg_id).to eq(out.id) # a ida anulada (mais antiga) nunca pareia
    expect(Tfd::CompleteLeg.call(leg: back, by: committee)).to be_ok
    Tfd::CloseAccountability.call(tfd_case: tfd.reload, attrs: proof, by: committee)
  end

  def leg_json(leg) = Tfd::Json.case(tfd.reload)["legs"].find { |l| l["id"] == leg.id }

  it "retirada do passageiro anula a ida de frota aberta (passenger_removed); a prestação de contas fecha e a volta pareia com a ida viva" do
    trip = confirmed_trip!
    rider, leg = fleet_outbound!(trip)
    removed = Transport::RemovePassenger.call(passenger: rider, reason: "Paciente remarcou a viagem", by: dispatcher!)
    expect(removed).to be_ok
    expect(leg.reload).to have_attributes(void_reason: "passenger_removed", done_at: nil)
    expect(leg.voided_at).to be_present
    expect(leg_json(leg)).to include("voided" => true, "done" => false)

    closed = ticket_pair_and_close!
    expect(closed).to be_ok
    expect(tfd.reload.status).to eq("completed")
    expect(TfdAllowance.where(tfd_leg_id: leg.id)).to be_empty
  end

  it "cancelamento da viagem anula os trechos abertos de todos os passageiros (trip_cancelled), de qualquer processo" do
    trip = confirmed_trip!
    _, leg = fleet_outbound!(trip)
    other = tfd_case!(status: "authorized")
    other_leg = add_leg_for!(other, trip)
    expect(Transport::CancelTrip.call(trip: trip, reason: "Veículo quebrado na véspera", by: dispatcher!)).to be_ok
    expect(leg.reload.void_reason).to eq("trip_cancelled")
    expect(other_leg.reload.void_reason).to eq("trip_cancelled")
    expect(leg_json(leg)["voided"]).to be(true)

    expect(ticket_pair_and_close!).to be_ok
  end

  it "paciente no_show no fechamento: trecho anulado (no_show), sem ajuda de custo; a correção para boarded deixa registrar de novo, já feito" do
    davi = driver_user!
    trip = confirmed_trip!(driver: davi)
    rider, leg = fleet_outbound!(trip)
    close_trip!(trip, rider => { attendance: "no_show" })
    expect(leg.reload).to have_attributes(void_reason: "no_show", done_at: nil)
    expect(TfdAllowance.count).to eq(0)
    expect(tfd.reload.status).to eq("scheduled")

    corrected = Transport::CorrectAttendance.call(trip: trip.reload, items: [ { "passenger_id" => rider.id, "attendance" => "boarded" } ],
                                                  reason: "Paciente embarcou e o motorista errou", by: dispatcher!)
    expect(corrected).to be_ok
    expect(leg.reload.done_at).to be_nil # o anulado não volta

    again = add_leg!(direction: "outbound", mode: "fleet", date: trip.date.iso8601, trip_passenger_id: rider.id)
    expect(again.reload.done_at).to be_present
    expect(TfdAllowance.where(tfd_leg_id: again.id).pluck(:person, :kind)).to eq([ %w[patient ground_km] ])
    expect(tfd.reload.status).to eq("travelling")
  end

  it "viagem fechada com o paciente no_show: o trecho de frota registrado depois é recusado (nunca fecharia)" do
    trip = confirmed_trip!
    rider = tfd_rider!(trip)
    close_trip!(trip, rider => { attendance: "no_show" })
    result = Tfd::AddLeg.call(tfd_case: tfd, by: committee,
                              attrs: { "direction" => "outbound", "mode" => "fleet", "date" => trip.date.iso8601, "trip_passenger_id" => rider.id })
    expect(result.reason).to eq(:invalid_request)
    expect(result.details).to include(path: "trip_passenger_id")
    expect(TfdLeg.count).to eq(0)
  end

  it "o trecho já feito nunca é anulado (a retirada depois do fechamento é recusada antes)" do
    trip = confirmed_trip!
    rider, leg = fleet_outbound!(trip)
    close_trip!(trip, rider => { attendance: "boarded" })
    expect(leg.reload.done_at).to be_present
    expect(Transport::RemovePassenger.call(passenger: rider.reload, reason: "Retirada depois da viagem", by: dispatcher!).reason)
      .to eq(:trip_not_open)
    expect(leg.reload.voided_at).to be_nil
  end

  it "FW8: a volta de frota pareia com a ida da MESMA linha, mesmo havendo ida aberta mais antiga" do
    older = add_leg!(direction: "outbound", mode: "bus_ticket", date: (Date.current - 2).iso8601, ticket: ticket)
    trip = confirmed_trip!
    rider, outbound = fleet_outbound!(trip)
    back = add_leg!(direction: "return", mode: "fleet", date: trip.return_at.in_time_zone.to_date.iso8601, trip_passenger_id: rider.id)
    expect(back.outbound_leg_id).to eq(outbound.id)
    expect(back.outbound_leg_id).not_to eq(older.id)

    # Sem ida na linha, vale a regra da mais antiga aberta.
    ticket_back = add_leg!(direction: "return", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket)
    expect(ticket_back.outbound_leg_id).to eq(older.id)
  end

  def meals = TfdAllowance.where(tfd_case_id: tfd.id, kind: %w[meal_day meal_overnight])

  it "N1: ida segunda; volta de frota sexta cancelada → anulada; a volta nova pareia com a ida de segunda e ganha km e alimentação" do
    monday = Date.current - 6
    out = add_leg!(direction: "outbound", mode: "bus_ticket", date: monday.iso8601, ticket: ticket)
    expect(Tfd::CompleteLeg.call(leg: out, by: committee)).to be_ok
    friday_trip = confirmed_trip!(date: Date.current - 2)
    friday_rider = tfd_rider!(friday_trip)
    dead = add_leg!(direction: "return", mode: "fleet", date: friday_trip.return_at.in_time_zone.to_date.iso8601,
                    trip_passenger_id: friday_rider.id)
    expect(dead.outbound_leg_id).to eq(out.id)
    expect(Transport::CancelTrip.call(trip: friday_trip, reason: "Veículo quebrado na véspera", by: dispatcher!)).to be_ok
    expect(dead.reload.void_reason).to eq("trip_cancelled")

    back = add_leg!(direction: "return", mode: "bus_ticket", date: (Date.current - 1).iso8601, ticket: ticket)
    expect(back.outbound_leg_id).to eq(out.id)
    expect(Tfd::CompleteLeg.call(leg: back, by: committee)).to be_ok
    expect(TfdAllowance.where(tfd_leg_id: back.id).pluck(:person, :kind, :quantity))
      .to contain_exactly([ "patient", "ground_km", 8 ], [ "patient", "meal_overnight", 5 ])
  end

  it "N1: volta de frota com o paciente no_show → anulada; a volta nova pareia com a ida" do
    out = add_leg!(direction: "outbound", mode: "bus_ticket", date: (Date.current - 3).iso8601, ticket: ticket)
    expect(Tfd::CompleteLeg.call(leg: out, by: committee)).to be_ok
    trip = confirmed_trip!
    rider = tfd_rider!(trip)
    dead = add_leg!(direction: "return", mode: "fleet", date: trip.return_at.in_time_zone.to_date.iso8601, trip_passenger_id: rider.id)
    close_trip!(trip, rider => { attendance: "no_show" })
    expect(dead.reload.void_reason).to eq("no_show")

    back = add_leg!(direction: "return", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket)
    expect(back.outbound_leg_id).to eq(out.id)
    expect(Tfd::CompleteLeg.call(leg: back, by: committee)).to be_ok
    expect(meals.pluck(:tfd_leg_id, :kind, :quantity)).to eq([ [ back.id, "meal_overnight", 3 ] ])
  end

  it "N1: ida anulada depois de a volta parear → a ida nova recebe a volta e o par ganha a alimentação uma vez" do
    trip = confirmed_trip!(date: Date.current - 3)
    _, dead_out = fleet_outbound!(trip)
    back = add_leg!(direction: "return", mode: "bus_ticket", date: Date.current.iso8601, ticket: ticket)
    expect(back.outbound_leg_id).to eq(dead_out.id)
    expect(Transport::CancelTrip.call(trip: trip, reason: "Viagem de ida remarcada", by: dispatcher!)).to be_ok
    expect(dead_out.reload.void_reason).to eq("trip_cancelled")
    expect(Tfd::CompleteLeg.call(leg: back, by: committee)).to be_ok
    expect(meals).to be_empty

    new_out = add_leg!(direction: "outbound", mode: "bus_ticket", date: (Date.current - 3).iso8601, ticket: ticket)
    expect(back.reload.outbound_leg_id).to eq(new_out.id)
    expect(Tfd::CompleteLeg.call(leg: new_out, by: committee, at: Time.current)).to be_ok
    expect(meals.pluck(:tfd_leg_id, :kind, :quantity)).to eq([ [ back.id, "meal_overnight", 3 ] ])
    expect(Tfd::CompleteLeg.call(leg: new_out.reload, by: committee).reason).to eq(:tfd_leg_done)
    expect(meals.count).to eq(1)
  end

  def add_leg_for!(other, trip)
    rider = passenger!(trip, patient: other.patient, origin: "tfd", tfd_case: other, exception_reason: nil)
    result = Tfd::AddLeg.call(tfd_case: other, by: committee,
                              attrs: { "direction" => "outbound", "mode" => "fleet", "date" => trip.date.iso8601, "trip_passenger_id" => rider.id })
    raise "AddLeg recusou: #{result.reason}" if result.failure?

    result.payload.fetch(:leg)
  end
end
