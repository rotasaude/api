require "rails_helper"

# Módulo 30, Task 15 (ADR 0048; contrato §9; §14 T1): o transporte na linha do
# tempo. Entram o passageiro `boarded` de viagem não cancelada ("Viagem para
# <cidade>", ou "TFD para <cidade>" com origem tfd; occurred_at = saída) e o
# trecho de PASSAGEM do TFD feito ("TFD para <cidade>"; occurred_at = meio-dia
# local da data do trecho). Falta, pendente, retirado, viagem cancelada e
# trecho aberto ficam fora; o trecho de frota não entra em separado (já é o
# passageiro). detail_ref, unidade, profissional (nunca o motorista), situação
# e documento nulos nas duas visões. Não consulta o interruptor.
RSpec.describe Timeline::Sources::TransportSource do
  include ActiveJob::TestHelper

  let!(:city) { transport_city!(tfd: true) }
  let(:patient) { transport_patient! }
  let(:person) { Timeline::Person.for_patient(patient) }
  let(:ponta_grossa) { destination! }
  let(:londrina) { destination!(name: "Londrina", ibge: "4113700", km: 380) }
  let(:citizen_view) { { title: nil, summary: nil, status: nil, professional_name: nil, unit: nil } }

  def entries(**opts) = described_class.entries(person: person, before: nil, limit: 10, from: nil, to: nil, **opts)

  def staffed_trip!(date:, destination:, status: "done")
    trip!(date: date, vehicle: vehicle!, driver: driver_user!.transport_driver, status: status, destination: destination)
  end

  it "passageiro boarded: kind transport, título com a cidade, occurred_at = saída e o resto nulo" do
    trip = staffed_trip!(date: Date.current - 5, destination: ponta_grossa)
    rider = passenger!(trip, patient: patient, attendance: "boarded")

    entry = entries.sole

    expect(entry).to have_attributes(kind: "transport", source_id: rider.id, occurred_at: trip.departure_at, unit: nil, professional: nil,
                                     title: "Viagem para Ponta Grossa", summary: nil, status: nil, detail_ref: nil, document: nil,
                                     citizen: citizen_view.merge(title: "Viagem para Ponta Grossa"))
    expect(Timeline::Json.professional(entry)).to include(kind: "transport", unit: nil, professional: nil, status: nil, detail_ref: nil)
    expect(Timeline::Json.citizen(entry)).to include(kind: "transport", title: "Viagem para Ponta Grossa", unit: nil, professional_name: nil,
                                                     status: nil, summary: nil, document: nil)
  end

  it "origem tfd: 'TFD para Londrina'; as outras origens 'Viagem para Ponta Grossa'" do
    tfd = tfd_case!(status: "authorized", patient: patient, destination: londrina)
    to_londrina = staffed_trip!(date: Date.current - 3, destination: londrina)
    passenger!(to_londrina, patient: patient, origin: "tfd", tfd_case: tfd, exception_reason: nil, attendance: "boarded")
    to_pg = staffed_trip!(date: Date.current - 4, destination: ponta_grossa)
    passenger!(to_pg, patient: patient, attendance: "boarded")

    expect(entries.map(&:title)).to eq([ "TFD para Londrina", "Viagem para Ponta Grossa" ])
  end

  it "falta, pendente, retirado, viagem cancelada e paciente de outro: fora" do
    kept = passenger!(staffed_trip!(date: Date.current - 1, destination: ponta_grossa), patient: patient, attendance: "boarded")
    passenger!(staffed_trip!(date: Date.current - 2, destination: ponta_grossa), patient: patient, attendance: "no_show")
    passenger!(staffed_trip!(date: Date.current - 3, destination: ponta_grossa), patient: patient)
    passenger!(staffed_trip!(date: Date.current - 4, destination: ponta_grossa), patient: patient, attendance: "boarded",
                                                                                   removed_at: Time.current, removed_by_user: dispatcher!,
                                                                                   remove_reason: "Paciente desistiu da viagem")
    cancelled = staffed_trip!(date: Date.current - 6, destination: ponta_grossa)
    passenger!(cancelled, patient: patient, attendance: "boarded")
    cancelled.update!(status: "cancelled", cancelled_at: Time.current, cancelled_by_user: dispatcher!, cancel_reason: "Veículo quebrado na estrada")
    passenger!(staffed_trip!(date: Date.current - 7, destination: ponta_grossa), patient: transport_patient!, attendance: "boarded")

    expect(entries.map(&:source_id)).to eq([ kept.id ])
  end

  it "trecho de passagem feito: source_id = trecho, meio-dia local da data, 'TFD para Londrina'; trecho aberto fora" do
    tfd = tfd_case!(status: "authorized", patient: patient, destination: londrina)
    on = Date.current - 2
    leg = tfd_leg_done!(tfd, "outbound", on)
    open = Tfd::AddLeg.call(tfd_case: tfd.reload, by: committee!,
                            attrs: { "direction" => "return", "mode" => "bus_ticket", "date" => Date.current.iso8601,
                                     "ticket" => { "amount_cents" => 15_000, "carrier" => "Viação Teste" } })
    expect(open).to be_ok

    entry = entries.sole

    expect(entry).to have_attributes(kind: "transport", source_id: leg.id, occurred_at: Time.zone.parse("#{on.iso8601} 12:00"),
                                     title: "TFD para Londrina", unit: nil, professional: nil, status: nil, detail_ref: nil, document: nil,
                                     citizen: citizen_view.merge(title: "TFD para Londrina"))
    expect(entry.occurred_at.in_time_zone.strftime("%Y-%m-%d %H:%M")).to eq("#{on.iso8601} 12:00")
  end

  it "trecho de frota feito não entra em separado: só o passageiro" do
    tfd = tfd_case!(status: "authorized", patient: patient, destination: londrina)
    trip = trip!(date: Date.current, vehicle: vehicle!, driver: driver_user!.transport_driver, status: "confirmed", destination: londrina)
    rider = passenger!(trip, patient: patient, origin: "tfd", tfd_case: tfd, exception_reason: nil)
    added = Tfd::AddLeg.call(tfd_case: tfd.reload, by: committee!,
                             attrs: { "direction" => "outbound", "mode" => "fleet", "date" => Date.current.iso8601, "trip_passenger_id" => rider.id })
    expect(added).to be_ok
    close_trip!(trip, rider => { attendance: "boarded" })
    expect(added.payload.fetch(:leg).reload.done_at).to be_present

    expect(entries.map { |e| [ e.source_id, e.title ] }).to eq([ [ rider.id, "TFD para Londrina" ] ])
  end

  it "página: ordem total e cursor atravessam passageiros e trechos; from/to recortam" do
    tfd = tfd_case!(status: "authorized", patient: patient, destination: londrina)
    leg = tfd_leg_done!(tfd, "outbound", Date.current - 2)
    newer = passenger!(staffed_trip!(date: Date.current - 1, destination: ponta_grossa), patient: patient, attendance: "boarded")
    older = passenger!(staffed_trip!(date: Date.current - 3, destination: ponta_grossa), patient: patient, attendance: "boarded")

    expect(entries.map(&:source_id)).to eq([ newer.id, leg.id, older.id ])
    expect(described_class.entries(person: person, before: nil, limit: 2, from: nil, to: nil).map(&:source_id)).to eq([ newer.id, leg.id ])

    first = Timeline::Query.call(person: person, kinds: %w[transport], limit: 2)
    rest = Timeline::Query.call(person: person, kinds: %w[transport], limit: 2, before: Timeline::Cursor.decode(first.next_before))
    expect(rest.entries.map(&:source_id)).to eq([ older.id ])

    from = Time.zone.parse("#{(Date.current - 2).iso8601} 00:00")
    to = Time.zone.parse("#{(Date.current - 2).iso8601} 23:59")
    expect(described_class.entries(person: person, before: nil, limit: 10, from: from, to: to).map(&:source_id)).to eq([ leg.id ])
  end

  it "não consulta o interruptor: com o transporte desligado a entrada continua; sem paciente, vazio" do
    rider = passenger!(staffed_trip!(date: Date.current - 1, destination: ponta_grossa), patient: patient, attendance: "boarded")
    Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
    expect(entries.map(&:source_id)).to eq([ rider.id ])

    nobody = Timeline::Person.new(citizen_ids: [], patient_id: nil, verified: false)
    expect(described_class.entries(person: nobody, before: nil, limit: 10, from: nil, to: nil)).to eq([])
  end

  it "Timeline::Query: o profissional recebe kind transport; o cidadão validado também" do
    passenger!(staffed_trip!(date: Date.current - 1, destination: ponta_grossa), patient: patient, attendance: "boarded")

    page = Timeline::Query.call(person: person)
    expect(page.entries.map(&:kind)).to include("transport")
    expect(Timeline::Query.citizen_kinds(verified: true, documents: true)).to include("transport")
    expect(Timeline::Query.citizen_kinds(verified: false, documents: true)).not_to include("transport")
  end
end
