require "rails_helper"

# Módulo 30, Task 5 (ADR 0048; contrato §2, §4; §14 T5, T17, T18, T19, T23;
# plano, Desvios 3–6): passageiros da viagem e atendimentos marcados.
RSpec.describe "Transporte — passageiros", type: :request do
  let!(:city) { transport_city!(tfd: true) }
  # Com motorista: confirmada, em andamento e feita exigem a escala (ck_transport_trips_staffed).
  let(:trip) { trip!(vehicle: vehicle!(seats: 2, wheelchair_spots: 1), driver: driver_user!.transport_driver) }
  let(:stop) { trip.transport_trip_stops.find_by!(kind: "boarding") }
  let(:trip_destination) { trip.transport_trip_stops.find_by!(kind: "destination").transport_destination }
  def add(patient, **over)
    json_post "/transport/trips/#{trip.id}/passengers", { patient_id: patient.id, origin: "exception", exception_reason: "legacy_patient",
                                                          stop_id: stop.id, destination_id: trip_destination.id,
                                                          takes_seat: true, wheelchair: false }.merge(over)
  end
  # Sem `.last`: id é UUID (memória "Flakies de UUID e relógio"); confere o payload por inclusão.
  def events(name) = DomainEvent.where(name: name)

  before { sign_in_as(dispatcher!) }

  it "lotação conta passageiro e acompanhante; cadeira tem vaga própria" do
    add(transport_patient!(birth_date: "2015-01-01"), companion: { name: "Mãe da Criança", document: "12345678900" })
    expect(response).to have_http_status(:created)
    expect(json_body).to include("companion" => { "name" => "Mãe da Criança", "document_last4" => "8900" }, "companion_attendance" => "pending")
    add(transport_patient!)
    expect(json_body["error"]).to eq("seats_full")
    add(transport_patient!, takes_seat: false, wheelchair: true)
    expect(response).to have_http_status(:created)
    add(transport_patient!, takes_seat: false, wheelchair: true)
    expect(json_body["error"]).to eq("wheelchair_full")
    expect(TransportTripPassenger.active.where(transport_trip: trip).count).to eq(2)
  end

  it "sem origem nem motivo → origin_required; other sem nota → exception_note; atendimento de outro paciente → origin_mismatch" do
    add(transport_patient!, origin: nil, exception_reason: nil)
    expect(json_body["error"]).to eq("origin_required")
    add(transport_patient!, exception_reason: "other")
    expect(json_body["path"]).to eq("exception_note")
    other_tfd = tfd_case!(status: "authorized")
    add(transport_patient!, origin: "tfd", origin_id: other_tfd.id, exception_reason: nil)
    expect(json_body["error"]).to eq("origin_mismatch")
    expect(TransportTripPassenger.count).to eq(0)
  end

  it "acompanhante de adulto de 40 anos exige motivo; no TFD só com indicação no laudo" do
    add(transport_patient!(birth_date: "1986-01-01"), companion: { name: "Irmão" })
    expect(json_body["error"]).to eq("companion_not_allowed")
    patient = transport_patient!(birth_date: "1986-01-01")
    tfd = tfd_case!(status: "authorized", patient: patient, report: { "companion_indicated" => false })
    add(patient, origin: "tfd", origin_id: tfd.id, exception_reason: nil, destination_id: tfd.transport_destination_id,
                 companion: { name: "Irmão", reason: "Paciente com baixa visão" })
    expect(json_body["error"]).to eq("companion_not_allowed")
    add(transport_patient!(birth_date: "1986-01-01"), companion: { name: "Irmão", reason: "Paciente com baixa visão" })
    expect(response).to have_http_status(:created)
  end

  it "nunca dado clínico nem CPF na forma do passageiro" do
    patient = transport_patient!
    tfd = tfd_case!(status: "authorized", patient: patient, report: { "justification" => "Sem nefrologia no município para hemodiálise" })
    add(patient, origin: "tfd", origin_id: tfd.id, exception_reason: nil, destination_id: tfd.transport_destination_id)
    expect(response).to have_http_status(:created)
    expect(response.body).not_to include("N185", "nefrologia", "0301010072", patient.cpf)
    expect(json_body["patient"].keys).to contain_exactly("id", "display_name", "has_cpf", "cns_masked", "phone_masked")
  end

  it "forma <passenger> (§2 + T18: destino com nome) e a <trip> passa a listar os passageiros ativos" do
    patient = transport_patient!
    add(patient, provider_name: "Hospital Regional", address: "Rua das Flores, 100", appointment_at: Time.zone.parse("#{trip.date} 09:30").iso8601)
    phone = Patients::Pairs.of(patient).first.phone
    expect(json_body).to eq(
      "id" => TransportTripPassenger.find_by!(transport_trip: trip, patient: patient).id,
      "patient" => { "id" => patient.id, "display_name" => patient.display_name, "has_cpf" => true, "cns_masked" => patient.cns_masked,
                     "phone_masked" => CitizenIdentity::Phone.mask(phone) },
      "stop_id" => stop.id,
      "destination" => { "destination_id" => trip_destination.id, "name" => trip_destination.name, "provider_name" => "Hospital Regional",
                         "address" => "Rua das Flores, 100" },
      "appointment_at" => Time.zone.parse("#{trip.date} 09:30").iso8601, "takes_seat" => true, "wheelchair" => false, "companion" => nil,
      "origin" => "exception", "exception_reason" => "legacy_patient", "attendance" => "pending", "companion_attendance" => nil
    )
    expect(response.body).not_to include(phone)
    driver_view = Transport::Json.passenger(TransportTripPassenger.find(json_body["id"]), viewer: :driver)
    expect(driver_view["patient"].keys).to contain_exactly("id", "display_name", "phone_masked")

    removed = transport_patient!
    add(removed, takes_seat: false)
    json_delete_with_body "/transport/trips/#{trip.id}/passengers/#{json_body['id']}", reason: "Paciente avisou que não vai"
    listed = Transport::Json.trip(trip.reload)["passengers"]
    expect(listed.map { |p| p["patient"]["id"] }).to eq([ patient.id ])
  end

  it "origem tfd: horário padrão do processo e prestador pelo nome; processo não autorizado → invalid_request em origin_id" do
    patient = transport_patient!
    tfd = tfd_case!(status: "authorized", patient: patient)
    tfd.update!(appointment_at: Time.zone.parse("#{trip.date} 13:00"))
    add(patient, origin: "tfd", origin_id: tfd.id, exception_reason: nil, destination_id: tfd.transport_destination_id)
    expect(json_body).to include("origin" => "tfd", "appointment_at" => Time.zone.parse("#{trip.date} 13:00").iso8601)
    expect(TransportTripPassenger.find(json_body["id"]).tfd_case_id).to eq(tfd.id)

    draft_patient = transport_patient!
    draft = tfd_case!(status: "draft", patient: draft_patient)
    add(draft_patient, origin: "tfd", origin_id: draft.id, exception_reason: nil, destination_id: draft.transport_destination_id)
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "origin_id" ])
  end

  it "C8: passageiro do TFD com destino diferente do processo → invalid_request em destination_id" do
    patient = transport_patient!
    tfd = tfd_case!(status: "authorized", patient: patient)
    expect(trip_destination.id).not_to eq(tfd.transport_destination_id)
    add(patient, origin: "tfd", origin_id: tfd.id, exception_reason: nil)
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "destination_id" ])
    expect(TransportTripPassenger.where(tfd_case_id: tfd.id)).to be_empty
  end

  it "C7: tfd desligado → origem tfd recusada 403 feature_disabled; a exceção segue" do
    patient = transport_patient!
    tfd = tfd_case!(status: "authorized", patient: patient)
    Platform::Features.set!(city: city, key: "tfd", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    add(patient, origin: "tfd", origin_id: tfd.id, exception_reason: nil, destination_id: tfd.transport_destination_id)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "tfd" } ])
    expect(TransportTripPassenger.where(tfd_case_id: tfd.id)).to be_empty
    add(patient)
    expect(response).to have_http_status(:created)
  end

  it "origem série: só a série ativa do paciente; suspensa ou encerrada → invalid_request em origin_id" do
    patient = transport_patient!
    series = lambda do |**over|
      TransportSeries.create!({ patient: patient, transport_destination: trip_destination, weekdays: [ 1, 3, 5 ], appointment_time: "07:00",
                                departure_time: "05:30", return_time: "12:00", boarding_label: "Praça Central",
                                starts_on: Date.current - 10, created_by_user: dispatcher! }.merge(over))
    end
    suspended = series.call(suspended_from: Date.current, suspend_reason: "Paciente internado no hospital")
    ended = series.call(ends_on: Date.current - 1)
    [ suspended, ended ].each do |s|
      add(patient, origin: "series", origin_id: s.id, exception_reason: nil)
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "origin_id" ])
    end
    add(patient, origin: "series", origin_id: series.call(suspended_from: Date.current + 30, suspend_reason: "Férias do paciente previstas").id,
                 exception_reason: nil)
    expect([ response.status, json_body["origin"] ]).to eq([ 201, "series" ])
  end

  it "parada de destino → stop_not_boarding; paciente, parada ou destino desconhecidos → 404; mesmo paciente duas vezes → patient_already_on_trip" do
    patient = transport_patient!
    add(patient, stop_id: trip.transport_trip_stops.find_by!(kind: "destination").id)
    expect(json_body["error"]).to eq("stop_not_boarding")
    add(patient, stop_id: trip!(date: Date.current + 5).transport_trip_stops.first.id)
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    add(patient, destination_id: SecureRandom.uuid)
    expect(response).to have_http_status(:not_found)
    json_post "/transport/trips/#{trip.id}/passengers", patient_id: SecureRandom.uuid, origin: "exception", exception_reason: "legacy_patient",
                                                        stop_id: stop.id, destination_id: trip_destination.id, takes_seat: true, wheelchair: false
    expect(response).to have_http_status(:not_found)
    add(patient)
    expect(response).to have_http_status(:created)
    add(patient)
    expect([ response.status, json_body["error"] ]).to eq([ 422, "patient_already_on_trip" ])
  end

  it "retirar exige motivo e libera a vaga; mesmo paciente de volta entra" do
    patient = transport_patient!
    add(patient)
    pid = json_body["id"]
    json_delete_with_body "/transport/trips/#{trip.id}/passengers/#{pid}", reason: "curto"
    expect([ response.status, json_body["path"] ]).to eq([ 422, "reason" ])
    json_delete_with_body "/transport/trips/#{trip.id}/passengers/#{pid}", reason: "Paciente avisou que não vai"
    expect(response).to have_http_status(:ok)
    expect(TransportTripPassenger.find(pid)).to have_attributes(removed_by_user_id: dispatcher!.id, remove_reason: "Paciente avisou que não vai")
    expect(TransportTripPassenger.find(pid).removed_at).to be_present
    add(patient)
    expect(response).to have_http_status(:created)
  end

  it "T19: escrita de passageiro em viagem in_progress, done ou cancelled → trip_not_open" do
    patient = transport_patient!
    open_passenger = passenger!(trip)
    %w[in_progress done cancelled].each do |status|
      trip.update_columns(status: status, cancelled_at: (Time.current if status == "cancelled"))
      add(patient)
      expect([ status, response.status, json_body["error"] ]).to eq([ status, 422, "trip_not_open" ])
      json_delete_with_body "/transport/trips/#{trip.id}/passengers/#{open_passenger.id}", reason: "Paciente avisou que não vai"
      expect([ status, json_body["error"] ]).to eq([ status, "trip_not_open" ])
    end
    expect(open_passenger.reload.removed_at).to be_nil
  end

  it "T23: retirar passageiro anonimizado → 422 passenger_anonymized, nunca 500" do
    passenger = passenger!(trip)
    passenger.update_columns(anonymized_at: Time.current) # o caminho real é o Transport::Anonymize (Task 17)
    json_delete_with_body "/transport/trips/#{trip.id}/passengers/#{passenger.id}", reason: "Paciente avisou que não vai"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "passenger_anonymized" } ])
    expect(passenger.reload.removed_at).to be_nil
  end

  it "toda entrada e retirada publica passenger_added/removed só com ids, planejada ou confirmada (o consumidor filtra)" do
    planned_patient = transport_patient!
    expect { add(planned_patient) }.to change { events("transport.passenger_added").count }.by(1)
    planned_id = json_body["id"]
    expect(events("transport.passenger_added").map(&:payload)).to include("trip_id" => trip.id, "passenger_id" => planned_id)
    expect { json_delete_with_body "/transport/trips/#{trip.id}/passengers/#{planned_id}", reason: "Paciente avisou que não vai" }
      .to change { events("transport.passenger_removed").count }.by(1)
    expect(events("transport.passenger_removed").map(&:payload)).to include("trip_id" => trip.id, "passenger_id" => planned_id)

    trip.update_columns(status: "confirmed", confirmed_at: Time.current)
    patient = transport_patient!
    expect { add(patient, takes_seat: false) }.to change { events("transport.passenger_added").count }.by(1)
    pid = json_body["id"]
    expect(events("transport.passenger_added").map(&:payload)).to include("trip_id" => trip.id, "passenger_id" => pid)
    expect { json_delete_with_body "/transport/trips/#{trip.id}/passengers/#{pid}", reason: "Paciente avisou que não vai" }
      .to change { events("transport.passenger_removed").count }.by(1)
    expect(events("transport.passenger_removed").map(&:payload)).to include("trip_id" => trip.id, "passenger_id" => pid)
  end

  it "passageiro de outra viagem → 404; só a central; transporte desligado → 403" do
    other = passenger!(trip!(date: Date.current + 6))
    json_delete_with_body "/transport/trips/#{trip.id}/passengers/#{other.id}", reason: "Paciente avisou que não vai"
    expect(response).to have_http_status(:not_found)
    sign_in_as(committee!)
    add(transport_patient!)
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    sign_in_as(dispatcher!)
    Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
    add(transport_patient!)
    expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
  end

  describe "POST /transport/scheduled_care" do
    it "devolve { items } dos atendimentos marcados; health_unit_id traz o 17; dado só no corpo" do
      day = Date.current + 2
      tfd = tfd_case!(status: "authorized")
      tfd.update!(appointment_at: Time.zone.parse("#{day} 10:00"))
      unit = create_unit("UBS Central do Transporte")
      appointment = transport_appointment!(transport_patient!, unit: unit, at: Time.zone.parse("#{day} 08:00"))
      json_post "/transport/scheduled_care", date: day.iso8601
      expect(response).to have_http_status(:ok)
      expect(json_body["items"].map { |item| [ item["origin"], item["origin_id"] ] }).to eq([ [ "tfd", tfd.id ] ])
      json_post "/transport/scheduled_care", date: day.iso8601, health_unit_id: unit.id
      expect(json_body["items"].map { |item| item["origin_id"] }).to eq([ appointment.id, tfd.id ])
      expect(response.body).not_to include("N185", "nefrologia", tfd.patient.cpf)

      json_post "/transport/scheduled_care", date: "amanhã"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "date" ])
      json_post "/transport/scheduled_care", date: day.iso8601, destination_id: "x"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "destination_id" ])
      post "/transport/scheduled_care?date=#{day.iso8601}", params: {}.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "date" ])
      sign_in_as(driver_user!)
      json_post "/transport/scheduled_care", date: day.iso8601
      expect(response).to have_http_status(:forbidden)
    end

    it "C7: com o tfd desligado, os itens do TFD ficam de fora; os outros seguem" do
      day = Date.current + 2
      tfd_case!(status: "authorized").update!(appointment_at: Time.zone.parse("#{day} 10:00"))
      unit = create_unit("UBS do Interruptor")
      appointment = transport_appointment!(transport_patient!, unit: unit, at: Time.zone.parse("#{day} 08:00"))
      Platform::Features.set!(city: city, key: "tfd", enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      json_post "/transport/scheduled_care", date: day.iso8601, health_unit_id: unit.id
      expect(response).to have_http_status(:ok)
      expect(json_body["items"].map { |item| [ item["origin"], item["origin_id"] ] }).to eq([ [ "appointment", appointment.id ] ])
    end
  end
end
