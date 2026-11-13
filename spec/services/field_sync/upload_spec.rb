require "rails_helper"

# Módulo 24b (ADR 0052; contrato §9.3; Q27, Q31, Q32, Q45, Q46, Q51, Q53, Q54,
# Q56; preflight 1.9–1.11, 1.16, 2.T20c; Ruling A11): o envio do app. Cada item
# em ordem, na sua transação; idempotente pelo livro (field_sync_receipts): o
# mesmo client_uuid com o mesmo type → duplicate com o id, com outro type →
# rejected client_uuid_conflict. Item fora do esquema → só ele rejected
# invalid_request com o path relativo ao body. Recusado e stale_version não vão
# ao livro.
RSpec.describe "FieldSync::Upload", type: :model do
  let!(:city) { home_visit_city! }
  let(:team) { registry_team! }
  let(:acs) { field_agent!(team: team) }
  let(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:device) { FieldDevices::Register.call(user: acs, name: "Celular").payload.fetch(:device) }
  let(:today) { Time.zone.today }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def at_now = Time.current.change(usec: 0)
  def item(type, body, uuid: SecureRandom.uuid) = { "client_uuid" => uuid, "type" => type, "body" => body }
  def upload(*items, user: acs, dev: device) = FieldSync::Upload.call(items: items, device: dev, user: user)

  def visit_body(**over)
    { "team_id" => team.id, "occurred_at" => at_now.iso8601, "micro_area_id" => area.id, "property_type" => "1",
      "subject" => "none", "outcome" => 1, "reasons" => [ 1 ], "shared" => false }.merge(over.stringify_keys)
  end

  def typed(name = "Benedita Alves Rocha", birth_date: "1951-03-08")
    { "full_name" => name, "birth_date" => birth_date, "sex" => "female", "no_cpf_reason" => "3" }
  end

  def household_body(**over)
    { "micro_area_id" => area.id, "property_type" => "1", "refused" => false, "contact_phone" => "4133334444",
      "address" => registry_address, "living_conditions" => registry_living_conditions }.merge(over.stringify_keys)
  end

  def activity_body(**over)
    { "team_id" => team.id, "held_on" => today.iso8601, "shift" => 2, "activity_type" => 5, "place_text" => "Salão paroquial",
      "participants_count" => 12, "target_audience" => [ 12 ], "health_topics" => [ 4 ],
      "participants" => [ { "patient_id" => registry_patient!.id } ] }.merge(over.stringify_keys)
  end

  def valid_response!(results)
    expect(FieldSync::Schemas.errors("upload-response-v1", { "results" => results }.as_json)).to eq([])
  end

  def statuses(results) = results.map { |result| result["status"] }
  def failure(result) = result.slice("status", "error", "path")
  def field_trail = DomainEvent.where(name: "clinical_record.viewed").select { |event| event.payload["access"] == "field_sync" }

  it "lote com paciente novo e visita que o cita por patient_client_uuid → dois accepted" do
    patient_uuid = SecureRandom.uuid
    visit_uuid = SecureRandom.uuid
    results = upload(item("patient", { "new_patient" => typed }, uuid: patient_uuid),
                     item("home_visit", visit_body(subject: "resident", patient_client_uuid: patient_uuid, reasons: [ 11 ]), uuid: visit_uuid))

    valid_response!(results)
    expect(statuses(results)).to eq(%w[accepted accepted])
    patient = Patient.find(results[0]["id"])
    expect(patient.full_name).to eq("Benedita Alves Rocha")
    visit = HomeVisit.find(results[1]["id"])
    expect(visit).to have_attributes(client_uuid: visit_uuid, patient_id: patient.id, origin: "field_app", field_device_id: device.id,
                                     recorded_by_user_id: acs.id)
    expect(results).to eq([ { "client_uuid" => patient_uuid, "status" => "accepted", "type" => "patient", "id" => patient.id },
                            { "client_uuid" => visit_uuid, "status" => "accepted", "type" => "home_visit", "id" => visit.id } ])
    expect(FieldSyncReceipt.order(:created_at).map { [ _1.client_uuid, _1.item_type, _1.result_type, _1.result_id, _1.user_id, _1.field_device_id ] })
      .to contain_exactly([ patient_uuid, "patient", "Patient", patient.id, acs.id, device.id ],
                          [ visit_uuid, "home_visit", "HomeVisit", visit.id, acs.id, device.id ])
  end

  it "domicílio novo, cadastro e visita que o citam por household_client_uuid e patient_client_uuid" do
    patient_uuid = SecureRandom.uuid
    household_uuid = SecureRandom.uuid
    registration = registry_registration_sections.deep_stringify_keys.merge(
      "is_responsible" => false, "household_client_uuid" => household_uuid, "patient_client_uuid" => patient_uuid,
      "patient_demographics" => { "race_color" => "01", "ethnicity" => nil }
    )
    registration["identification"] = registration["identification"].merge("desconhece_nome_mae" => true)
    visit = visit_body(subject: "resident", household_client_uuid: household_uuid, patient_client_uuid: patient_uuid, reasons: [ 11 ])
            .except("micro_area_id", "property_type")
    results = upload(item("patient", { "new_patient" => typed }, uuid: patient_uuid),
                     item("household", household_body, uuid: household_uuid),
                     item("individual_registration", registration),
                     item("home_visit", visit))

    valid_response!(results)
    expect(statuses(results)).to eq(%w[accepted accepted accepted accepted])
    household = Household.find(results[1]["id"])
    saved = IndividualRegistration.find(results[2]["id"])
    expect(saved).to have_attributes(patient_id: results[0]["id"], household_id: household.id)
    expect(HomeVisit.find(results[3]["id"])).to have_attributes(household_id: household.id, patient_id: results[0]["id"])
    expect(FieldSyncReceipt.pluck(:item_type)).to contain_exactly("patient", "household", "individual_registration", "home_visit")
  end

  it "citação de item não aceito → rejected not_found com o path do campo (Q27)" do
    results = upload(item("home_visit", visit_body(subject: "resident", patient_client_uuid: SecureRandom.uuid, reasons: [ 11 ])),
                     item("home_visit", visit_body(household_client_uuid: SecureRandom.uuid).except("micro_area_id", "property_type")))
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([ { "status" => "rejected", "error" => "not_found", "path" => "patient_client_uuid" },
                                                { "status" => "rejected", "error" => "not_found", "path" => "household_client_uuid" } ])
    expect(HomeVisit.count).to eq(0)
  end

  it "item recusado no meio não derruba os outros" do
    results = upload(item("home_visit", visit_body),
                     item("home_visit", visit_body(occurred_at: (at_now - 400.days).iso8601)),
                     { "client_uuid" => SecureRandom.uuid, "type" => "family", "body" => {} },
                     item("home_visit", visit_body(reasons: [ 27 ])))

    valid_response!(results)
    expect(statuses(results)).to eq(%w[accepted rejected rejected accepted])
    expect(failure(results[1])).to eq("status" => "rejected", "error" => "visit_date_out_of_range", "path" => "occurred_at")
    expect(results[2]).to eq("client_uuid" => results[2]["client_uuid"], "status" => "rejected", "error" => "invalid_request", "path" => "type")
    expect(HomeVisit.count).to eq(2)
    expect(FieldSyncReceipt.count).to eq(2)
  end

  it "item fora do esquema → rejected invalid_request com o path da Q32/Q46" do
    two_places = activity_body(place_health_unit_id: SecureRandom.uuid)
    results = upload(
      item("home_visit", visit_body.except("occurred_at")),
      item("home_visit", visit_body(reasons: [ 26 ])),
      item("home_visit", visit_body(measurements: { "systolic" => 120 })),
      item("home_visit", visit_body(household_id: SecureRandom.uuid, household_client_uuid: SecureRandom.uuid)),
      item("home_visit", []),
      { "client_uuid" => "C0FFEE01-0000-4000-8000-000000000001", "type" => "home_visit", "body" => visit_body },
      item("collective_activity", two_places),
      item("collective_activity", activity_body(participants: [ { "patient_id" => SecureRandom.uuid }, { "new_patient" => typed.except("full_name") } ]))
    )

    valid_response!(results)
    expect(results.map { _1["path"] }).to eq(%w[occurred_at reasons[0] measurements body body client_uuid body
                                                participants[1].new_patient.full_name])
    expect(results.map { _1["error"] }.uniq).to eq(%w[invalid_request])
    expect(results[5]).not_to have_key("client_uuid")
    expect(results[5]["type"]).to eq("home_visit")
    expect(HomeVisit.count + CollectiveActivity.count + FieldSyncReceipt.count).to eq(0)
  end

  it "reenvio do lote inteiro → duplicate com os mesmos ids, nenhuma linha nova, nenhum evento novo" do
    patient_uuid = SecureRandom.uuid
    batch = [ item("patient", { "new_patient" => typed }, uuid: patient_uuid),
              item("home_visit", visit_body(subject: "resident", patient_client_uuid: patient_uuid, reasons: [ 11 ])),
              item("household", household_body) ]
    first = upload(*batch)
    expect(statuses(first)).to eq(%w[accepted accepted accepted])
    counts = -> { [ Patient.count, HomeVisit.count, Household.count, HouseholdVersion.count, FieldSyncReceipt.count, DomainEvent.count ] }
    before = counts.call

    again = upload(*batch)
    valid_response!(again)
    expect(statuses(again)).to eq(%w[duplicate duplicate duplicate])
    expect(again.map { _1["id"] }).to eq(first.map { _1["id"] })
    expect(counts.call).to eq(before)
  end

  it "mesmo client_uuid com outro type → client_uuid_conflict; o de outro usuário também" do
    uuid = SecureRandom.uuid
    expect(statuses(upload(item("home_visit", visit_body, uuid: uuid)))).to eq(%w[accepted])

    conflict = upload(item("patient", { "new_patient" => typed }, uuid: uuid))
    valid_response!(conflict)
    expect(conflict.sole.slice("client_uuid", "status", "type", "error"))
      .to eq("client_uuid" => uuid, "status" => "rejected", "type" => "patient", "error" => "client_uuid_conflict")

    other = field_agent!(team: team)
    other_area = registry_micro_area!(code: "02", team: team, acs: other)
    other_device = FieldDevices::Register.call(user: other, name: "Tablet").payload.fetch(:device)
    stolen = upload(item("home_visit", visit_body(micro_area_id: other_area.id), uuid: uuid), user: other, dev: other_device)
    expect(stolen.sole.slice("status", "error")).to eq("status" => "rejected", "error" => "client_uuid_conflict")
    expect(Patient.where(full_name: "Benedita Alves Rocha")).to be_empty
    expect(FieldSyncReceipt.count).to eq(1)
  end

  it "recusado reenviado corrigido → accepted" do
    uuid = SecureRandom.uuid
    refused = upload(item("home_visit", visit_body(occurred_at: (at_now - 400.days).iso8601), uuid: uuid))
    expect(failure(refused.sole)).to include("status" => "rejected", "error" => "visit_date_out_of_range")
    expect(FieldSyncReceipt.count).to eq(0)

    fixed = upload(item("home_visit", visit_body, uuid: uuid))
    expect(fixed.sole).to include("status" => "accepted", "client_uuid" => uuid)
    expect(FieldSyncReceipt.sole.result_id).to eq(fixed.sole["id"])
  end

  it "visita de dia já fechado entra na complementar" do
    closed = home_visit_day!(agent: acs, team: team, state: "closed")
    result = upload(item("home_visit", visit_body)).sole
    expect(result["status"]).to eq("accepted")
    day = HomeVisit.find(result["id"]).home_visit_day
    expect(day).to have_attributes(sequence: 2, state: "open", day: closed.day)
    expect(day.id).not_to eq(closed.id)
  end

  it "household com version vencida → stale_version com current (e trilha field_sync); nada no livro" do
    household = registry_household!(micro_area: area)
    updated = TerritoryRegistry::SaveHousehold.call(params: registry_household_params(household).merge("version" => 1, "contact_phone" => "4130000000"),
                                                    by: acs, household: household)
    expect(updated).to be_ok
    versions = HouseholdVersion.count
    body = registry_household_params(household).merge("household_id" => household.id, "version" => 1)

    result = upload(item("household", body)).sole
    valid_response!([ result ])
    expect(result).to include("status" => "stale_version", "type" => "household", "id" => household.id, "current_version" => 2)
    expect(result["current"]).to include("id" => household.id, "version" => 2, "contact_phone" => "4130000000")
    expect(HouseholdVersion.count).to eq(versions)
    expect(FieldSyncReceipt.count).to eq(0)
    expect(field_trail.map { _1.payload.slice("household_ids", "user_id", "field_device_id") })
      .to eq([ { "household_ids" => [ household.id ], "user_id" => acs.id, "field_device_id" => device.id } ])

    current = upload(item("household", body.merge("version" => 2))).sole
    expect(current).to include("status" => "accepted", "id" => household.id)
    expect(household.reload.version).to eq(3)
  end

  it "cadastro com version vencida → stale_version com current; domicílio que não enxerga → not_found" do
    registration = registry_registration!(household: registry_household!(micro_area: area))
    params = registry_registration_params(registration.household, patient: registration.patient)
    expect(TerritoryRegistry::SaveRegistration.call(params: params.merge("version" => 1), by: acs, registration: registration)).to be_ok
    expect(registration.reload.version).to eq(2)
    body = params.merge("registration_id" => registration.id, "version" => 1)

    result = upload(item("individual_registration", body)).sole
    valid_response!([ result ])
    expect(result).to include("status" => "stale_version", "id" => registration.id, "current_version" => 2)
    expect(result["current"]).to include("id" => registration.id, "version" => 2)

    foreign = registry_household!(micro_area: registry_micro_area!(code: "07", team: team))
    hidden = upload(item("household", registry_household_params(foreign).merge("household_id" => foreign.id, "version" => 1))).sole
    expect(failure(hidden)).to eq("status" => "rejected", "error" => "not_found", "path" => "household_id")
  end

  it "TACS mandando household ou cadastro → rejected cbo_not_allowed (W-9)" do
    tacs = field_agent!(cbo: "322255", team: team)
    assignment!(area, tacs.professional)
    tacs_device = FieldDevices::Register.call(user: tacs, name: "Tablet").payload.fetch(:device)
    results = upload(item("household", household_body),
                     item("individual_registration", registry_registration_params(team).merge("new_patient" => typed)),
                     user: tacs, dev: tacs_device)
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([ { "status" => "rejected", "error" => "cbo_not_allowed" } ] * 2)
    expect(Household.count + FieldSyncReceipt.count).to eq(0)
  end

  it "collective_activities desligado → item rejected feature_disabled; ligado, aceita com patient_client_uuid" do
    patient_uuid = SecureRandom.uuid
    activity = activity_body(participants: [ { "patient_client_uuid" => patient_uuid } ])
    off = upload(item("patient", { "new_patient" => typed }, uuid: patient_uuid), item("collective_activity", activity))
    valid_response!(off)
    expect(off.map { failure(_1) }.last).to eq("status" => "rejected", "error" => "feature_disabled")
    expect(CollectiveActivity.count).to eq(0)

    Platform::Features.set!(city: city, key: CollectiveActivities::Gate::KEY, enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    on = upload(item("collective_activity", activity)).sole
    expect(on["status"]).to eq("accepted")
    saved = CollectiveActivity.find(on["id"])
    expect(saved).to have_attributes(origin: "field_app", field_device_id: device.id)
    expect(saved.participants.sole.patient_id).to eq(off.first["id"])

    twice = upload(item("collective_activity", activity_body(participants: [ { "patient_client_uuid" => patient_uuid },
                                                                            { "patient_id" => off.first["id"] } ]))).sole
    valid_response!([ twice ])
    expect(twice).to include("status" => "rejected", "error" => "duplicate_participant", "path" => "participants[1]", "confirmable" => false)
  end

  it "retirada por visit_client_uuid; reenvio → duplicate; outra retirada → visit_changed; folha fechada → day_closed" do
    visit_uuid = SecureRandom.uuid
    upload(item("home_visit", visit_body, uuid: visit_uuid))
    withdrawal = item("home_visit_withdrawal", { "visit_client_uuid" => visit_uuid, "reason" => "Registrada na casa errada" })
    first = upload(withdrawal).sole
    visit = HomeVisit.find_by!(client_uuid: visit_uuid)
    expect(first).to include("status" => "accepted", "id" => visit.id)
    expect(visit.reload).to be_withdrawn
    expect(upload(withdrawal).sole).to include("status" => "duplicate", "id" => visit.id)
    again = upload(item("home_visit_withdrawal", { "visit_id" => visit.id, "reason" => "Registrada na casa errada" })).sole
    expect(failure(again)).to include("status" => "rejected", "error" => "visit_changed")

    other = upload(item("home_visit", visit_body)).sole
    HomeVisits::CloseDay.call(HomeVisit.find(other["id"]).home_visit_day, by: acs, closed_by: "user")
    closed = upload(item("home_visit_withdrawal", { "visit_id" => other["id"], "reason" => "Registrada na casa errada" })).sole
    expect(failure(closed)).to include("status" => "rejected", "error" => "day_closed")
    missing = upload(item("home_visit_withdrawal", { "visit_client_uuid" => SecureRandom.uuid, "reason" => "Registrada na casa errada" })).sole
    expect(failure(missing)).to eq("status" => "rejected", "error" => "not_found", "path" => "visit_client_uuid")
    valid_response!([ first, again, closed, missing ])
  end

  it "paciente com duplicado suspeito → rejected com candidates e trilha field_sync, sem paciente novo" do
    existing = registry_patient!
    before = Patient.count
    result = upload(item("patient", { "new_patient" => typed(existing.full_name, birth_date: existing.birth_date.to_s) })).sole
    valid_response!([ result ])
    expect(result).to include("status" => "rejected", "error" => "duplicate_suspected")
    expect(result["candidates"].map { _1["patient_id"] }).to eq([ existing.id ])
    expect(Patient.count).to eq(before)
    expect(FieldSyncReceipt.count).to eq(0)
    expect(field_trail.map { _1.payload.slice("patient_id", "user_id", "field_device_id") })
      .to eq([ { "patient_id" => existing.id, "user_id" => acs.id, "field_device_id" => device.id } ])
  end
end
