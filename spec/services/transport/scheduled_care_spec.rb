require "rails_helper"

# Módulo 30, Task 5 (ADR 0048; contrato §4; §14 T5; plano, Desvio 6):
# atendimentos marcados na data ainda sem viagem — pedido do 26a `scheduled`,
# horário do 17 (só com health_unit_id) e TFD com atendimento na data. O texto
# livre `schedule_place` nunca vira provider_name; nada de alvo, CID ou
# justificativa no item.
RSpec.describe Transport::ScheduledCare do
  include ActiveSupport::Testing::TimeHelpers

  before do
    regulation_city!
    tick_regulation_events!
  end

  let(:day) { Time.zone.today + 3 }
  let(:araucaria) { destination!(name: "Araucária", ibge: "4101804", km: 27, metropolitan: true) }
  let(:londrina) { destination!(name: "Londrina", ibge: "4113700", km: 380) }
  let(:place) { "Clínica de Olhos Araucária, sala 3" }

  def at(hhmm, on: day) = Time.zone.parse("#{on.iso8601} #{hhmm}")

  def scheduled_request!(at:, provider: nil)
    request = regulation_request!(status: "external")
    result = CareRegulation::ScheduleExternal.call(request: request, at: at.iso8601, place: place, notes: "Levar exames anteriores",
                                                   version: request.version, by: regulation_regulator!,
                                                   care_provider_id: provider&.id)
    raise "agendamento recusado: #{result.reason}" if result.failure?

    request.reload
  end

  def provider_in(ibge) = external_provider!(name: "Hospital Regional #{ibge}").tap { |p| p.update!(ibge_code: ibge) }
  def item_for(items, origin, id) = items.find { |item| item["origin"] == origin && item["origin_id"] == id }

  it "pedido do 26a com prestador em município cadastrado: destination_id e o NOME do prestador, nunca o schedule_place" do
    provider = provider_in(araucaria.ibge_code)
    request = scheduled_request!(at: at("09:30"), provider: provider)
    items = described_class.call(date: day)
    item = item_for(items, "regulation", request.id)
    expect(item).to eq(
      "patient" => { "id" => request.patient_id, "display_name" => request.patient.display_name, "has_cpf" => true,
                     "cns_masked" => request.patient.cns_masked,
                     "phone_masked" => CitizenIdentity::Phone.mask(Patients::Pairs.of(request.patient).first.phone) },
      "origin" => "regulation", "origin_id" => request.id, "appointment_at" => at("09:30").iso8601,
      "destination" => { "destination_id" => araucaria.id, "provider_name" => provider.name, "address" => nil }
    )
    expect(items.to_s).not_to include("Clínica de Olhos", "Levar exames", "225120", "I10", "Hipertensão")
  end

  it "prestador sem município cadastrado ou sem prestador: destination_id nulo; outro dia fica de fora" do
    no_dest = scheduled_request!(at: at("10:00"), provider: provider_in("4119905"))
    no_provider = scheduled_request!(at: at("11:00"))
    other_day = scheduled_request!(at: at("10:00", on: day + 1))
    items = described_class.call(date: day)
    expect(item_for(items, "regulation", no_dest.id)["destination"])
      .to eq("destination_id" => nil, "provider_name" => "Hospital Regional 4119905", "address" => nil)
    expect(item_for(items, "regulation", no_provider.id)["destination"])
      .to eq("destination_id" => nil, "provider_name" => nil, "address" => nil)
    expect(item_for(items, "regulation", other_day.id)).to be_nil
    expect(items.to_s).not_to include("Clínica de Olhos")
  end

  it "horário do 17 só entra com health_unit_id (da unidade pedida, vivo, na data)" do
    unit = create_unit("UBS Transporte")
    other_unit = create_unit("UBS Outra")
    patient = transport_patient!
    appointment = transport_appointment!(patient, unit: unit, at: at("08:00"))
    transport_appointment!(transport_patient!, unit: other_unit, at: at("08:30"))
    transport_appointment!(transport_patient!, unit: unit, at: at("08:00", on: day + 1))
    expect(described_class.call(date: day).map { |item| item["origin"] }).not_to include("appointment")

    items = described_class.call(date: day, health_unit_id: unit.id).select { |item| item["origin"] == "appointment" }
    expect(items).to eq([ { "patient" => Transport::Json.patient(patient), "origin" => "appointment", "origin_id" => appointment.id,
                            "appointment_at" => at("08:00").iso8601,
                            "destination" => { "destination_id" => nil, "provider_name" => nil, "address" => nil } } ])
  end

  it "TFD autorizado com atendimento na data entra com o destino do processo; rascunho e outro dia não" do
    authorized = tfd_case!(status: "authorized", destination: londrina)
    authorized.update!(appointment_at: at("14:00"))
    tfd_case!(status: "submitted", destination: londrina).update!(appointment_at: at("14:00"))
    tfd_case!(status: "authorized", destination: londrina).update!(appointment_at: at("14:00", on: day + 2))
    items = described_class.call(date: day).select { |item| item["origin"] == "tfd" }
    expect(items.map { |item| item["origin_id"] }).to eq([ authorized.id ])
    expect(items.first).to include("appointment_at" => at("14:00").iso8601,
                                   "destination" => { "destination_id" => londrina.id, "provider_name" => nil, "address" => nil })
    expect(items.to_s).not_to include("N185", "nefrologia", "0301010072", "Doença renal")
  end

  it "quem já está em viagem ativa com a mesma origem fica de fora; viagem cancelada ou passageiro retirado não contam" do
    on_trip = tfd_case!(status: "authorized", destination: londrina).tap { |c| c.update!(appointment_at: at("14:00")) }
    cancelled = tfd_case!(status: "authorized", destination: londrina).tap { |c| c.update!(appointment_at: at("15:00")) }
    removed = tfd_case!(status: "authorized", destination: londrina).tap { |c| c.update!(appointment_at: at("16:00")) }
    trip = trip!(date: day, destination: londrina)
    passenger!(trip, patient: on_trip.patient, origin: "tfd", tfd_case: on_trip, exception_reason: nil)
    passenger!(trip, patient: removed.patient, origin: "tfd", tfd_case: removed, exception_reason: nil)
      .update!(removed_at: Time.current, remove_reason: "Paciente desistiu da viagem")
    cancelled_trip = trip!(date: day, destination: londrina, departure: "06:00")
    passenger!(cancelled_trip, patient: cancelled.patient, origin: "tfd", tfd_case: cancelled, exception_reason: nil)
    cancelled_trip.update!(status: "cancelled", cancelled_at: Time.current, cancel_reason: "Veículo quebrado na estrada")

    ids = described_class.call(date: day).select { |item| item["origin"] == "tfd" }.map { |item| item["origin_id"] }
    expect(ids).to contain_exactly(cancelled.id, removed.id)
  end

  it "destination_id filtra pelo destino; itens por horário" do
    later = tfd_case!(status: "authorized", destination: londrina).tap { |c| c.update!(appointment_at: at("15:00")) }
    request = scheduled_request!(at: at("09:30"), provider: provider_in(araucaria.ibge_code))
    earlier = tfd_case!(status: "authorized", destination: londrina).tap { |c| c.update!(appointment_at: at("07:00")) }
    expect(described_class.call(date: day).map { |item| item["origin_id"] }).to eq([ earlier.id, request.id, later.id ])
    expect(described_class.call(date: day, destination_id: londrina.id).map { |item| item["origin_id"] }).to eq([ earlier.id, later.id ])
  end
end
