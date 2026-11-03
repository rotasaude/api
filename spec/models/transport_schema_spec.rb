require "rails_helper"
require Rails.root.join("db/city_migrate/20261103900001_add_sanitary_transport.rb").to_s

# Módulo 30 (ADR 0048): o banco do transporte sanitário e do TFD. Veículo e
# motorista sem sobreposição (exclusion GiST, intervalo [)), presença que
# congela com a viagem fechada, andamento e pagamento do TFD só acréscimo, e
# nada pessoal em inspect/as_json.
RSpec.describe "Esquema do módulo 30", type: :model do
  let!(:city) { transport_city! }

  # Escrita crua (delete, update_columns, SQL) que o banco recusa: sem savepoint,
  # a recusa aborta a transação do exemplo (o create!/update! já roda no dele).
  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  it "o banco recusa o mesmo veículo em viagens que se cruzam e aceita as encostadas" do
    van = vehicle!
    trip!(vehicle: van, departure: "07:00", back: "12:00")
    expect { trip!(vehicle: van, departure: "12:00", back: "15:00") }.not_to raise_error
    expect { trip!(vehicle: van, departure: "11:59", back: "13:00") }
      .to raise_error(ActiveRecord::ExclusionViolation, /excl_transport_trips_vehicle/)
  end

  it "o mesmo motorista também, e viagem cancelada não ocupa" do
    driver = driver_user!.transport_driver
    first = trip!(driver: driver, departure: "07:00", back: "12:00")
    expect { trip!(driver: driver, departure: "08:00", back: "09:00") }
      .to raise_error(ActiveRecord::ExclusionViolation, /excl_transport_trips_driver/)
    first.update_columns(status: "cancelled", cancelled_at: Time.current)
    expect { trip!(driver: driver, departure: "08:00", back: "09:00") }.not_to raise_error
  end

  it "confirmada exige veículo e motorista; planned sem escala vale" do
    expect { trip!(status: "planned") }.not_to raise_error
    expect { trip!(status: "confirmed") }.to raise_error(ActiveRecord::StatementInvalid, /ck_transport_trips_staffed/)
  end

  # Sem CHECK de data (o dump é um só para cidades de fuso diferente): a data
  # vem da saída no fuso da cidade, no Ruby. 05:30 local = 08:30 UTC.
  it "a data da viagem é o dia local da saída" do
    trip = trip!(date: Date.current + 2, departure: "05:30", back: "11:00")
    expect(trip.reload.date).to eq(Date.current + 2)
    expect(trip.departure_at.in_time_zone.strftime("%H:%M")).to eq("05:30")
    late = TransportTrip.new(departure_at: Time.zone.parse("#{Date.current + 3} 23:30"))
    late.valid?
    expect(late.date).to eq(Date.current + 3)
  end

  it "passageiro sem origem precisa de motivo; um por viagem enquanto ativo" do
    trip = trip!
    patient = transport_patient!
    expect { passenger!(trip, patient: patient, exception_reason: nil) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_transport_trip_passengers_origin/)
    passenger!(trip, patient: patient)
    expect { passenger!(trip, patient: patient) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "presença congela com a viagem done; correção só sob a marca, que volta a off depois do bloco" do
    trip = trip!(vehicle: vehicle!, driver: driver_user!.transport_driver, status: "confirmed")
    rider = passenger!(trip)
    expect { rider.update!(attendance: "boarded") }.to raise_error(ActiveRecord::StatementInvalid, /attendance is frozen/)
    trip.update_columns(status: "in_progress")
    rider.reload.update!(attendance: "boarded")
    trip.update_columns(status: "done")
    expect { rider.update!(attendance: "no_show") }.to raise_error(ActiveRecord::StatementInvalid, /attendance is frozen/)
    TransportTripPassenger.with_attendance_correction do
      expect { rider.reload.update!(attendance: "no_show") }.not_to raise_error
    end
    expect(rider.reload.attendance).to eq("no_show")
    expect { rider.update!(attendance: "boarded") }.to raise_error(ActiveRecord::StatementInvalid, /attendance is frozen/)
  end

  it "passageiro nunca some nem troca de viagem, paciente ou origem; retirada e anonimização uma vez" do
    rider = passenger!(trip!, companion_name: "Joana Acompanhante", companion_document: "12345678900", companion_attendance: "pending")
    refused(/DELETE refused/) { rider.delete }
    refused(/never change/) { rider.update_columns(patient_id: transport_patient!.id) }
    rider.update!(removed_at: Time.current, removed_by_user: dispatcher!, remove_reason: "Paciente desistiu da viagem")
    refused(/removed once/) { rider.update_columns(removed_at: Time.current + 1.hour) }
    refused(/only go to NULL/) { rider.update_columns(anonymized_at: Time.current, companion_name: "Outra Pessoa") }
    rider.update_columns(anonymized_at: Time.current, companion_name: nil, companion_document: nil, remove_reason: nil)
    refused(/anonymized/) { rider.update_columns(takes_seat: false) }
  end

  it "evento e pagamento do TFD são só acréscimo; processo não some" do
    tfd = tfd_case!
    event = TfdCaseEvent.create!(tfd_case: tfd, kind: "created", by_user: tfd.requester_user)
    refused { event.update_column(:kind, "submitted") }
    payment = TfdPayment.create!(tfd_case: tfd, paid_on: Date.current, amount_cents: 2475, payment_method: "pix", receipt_number: "R-1",
                                 by_user: tfd.requester_user)
    refused { payment.delete }
    refused { tfd.delete }
    expect(tfd.reload.report).to include("cid10" => "N185", "sigtap_code" => "0301010072", "companion_indicated" => true)
  end

  it "parada com passageiro não sai; aviso só é lido uma vez e pode ser apagado; TRUNCATE recusado" do
    trip = trip!
    rider = passenger!(trip)
    refused(/stop in use/) { rider.transport_trip_stop.delete }
    citizen = Patients::Pairs.of(rider.patient).first
    notice = TransportTripNotice.create!(transport_trip_passenger: rider, citizen: citizen, kind: "added", event_key: "once",
                                         departure_at: trip.departure_at, boarding_label: "Praça Central", sms: false)
    notice.update!(read_at: Time.current)
    refused(/read once/) { notice.update_columns(read_at: Time.current + 1.minute) }
    expect { notice.delete }.not_to raise_error
    refused(/TRUNCATE refused/) { ApplicationRecord.connection.execute("TRUNCATE transport_trip_passengers CASCADE") }
  end

  it "papéis, unidade de gestão e fonte tfd entram nas travas" do
    expect(Membership::PRIVILEGED_ROLES).to include("transport_dispatcher", "tfd_committee")
    expect(Membership::PRIVILEGED_ROLES).not_to include("driver")
    expect { staff_with("motorista-#{SecureRandom.hex(2)}@cidade.gov.br", "driver") }.not_to raise_error
    expect { health_management_unit! }.not_to raise_error
    expect(PerformedProcedure::SOURCES).to include("tfd")
    expect(AddSanitaryTransport::SOURCES).to eq(PerformedProcedure::SOURCES)
    expect(AddSanitaryTransport::HEALTH_UNIT_KINDS).to eq(HealthUnit::KINDS)
    expect(AddSanitaryTransport::EXPENSE_KINDS).not_to include("lodging")
  end

  it "parâmetros: uma linha só, com os padrões" do
    settings = TransportSetting.current
    expect([ settings.id, settings.tfd_min_distance_km, settings.companion_max_age_child, settings.companion_min_age_elderly ])
      .to eq([ 1, 50, 15, 60 ])
    refused(/ck_transport_settings_singleton/) { TransportSetting.connection.execute("INSERT INTO transport_settings (id, updated_at) VALUES (2, now())") }
    refused { settings.delete }
  end

  it "nada pessoal em inspect/as_json" do
    rider = passenger!(trip!, companion_name: "Joana Acompanhante", companion_document: "12345678900", companion_attendance: "pending")
    expect([ rider.inspect, rider.to_s, rider.as_json.to_s ].join).not_to include("Joana")
    expect(rider.as_json).to eq("id" => rider.id)
    driver = driver_user!.transport_driver
    expect(driver.inspect).to eq("#<TransportDriver id=#{driver.id}>")
    expect(driver.inspect).not_to include(driver.license_number)
    tfd = tfd_case!
    expect(tfd.as_json).to eq("id" => tfd.id)
    expect([ tfd.inspect, tfd.to_s ].join).not_to include("N185")
  end
end
