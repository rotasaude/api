require "rails_helper"

# Módulo 35a, Task 15 (ADR 0054; contrato §13; Q6, Q7(1), Q7(2), Q7(5), Q10,
# Q13(2); CV-3, CV-4, CV-6, CV-9, CV-10): o envio do app de campo na v1.3.0.
#   - home_visit com vector_inspection (o gate lido fora da transação e
#     passado ao HomeVisits::Record) → accepted com vector_inspection_id; o
#     reenvio → duplicate com o mesmo id;
#   - ovitrap_installation e ovitrap_collection só do agente de endemias com o
#     gate; o `id` dos dois é o da ovitrampa (sem ovitrap_id); a coleta cita a
#     instalação do mesmo lote por ovitrap_client_uuid (itens em ordem, Q10);
#   - erro de esquema dentro do boletim → vector_inspection_invalid com o path.
# Toda resposta validada contra o upload-response-v1 da v1.3.0.
RSpec.describe "FieldSync::Upload — vigilância ambiental (v1.3.0)", type: :model do
  let!(:city) { vector_city! }
  let(:team) { registry_team! }
  let(:agent) { endemic_agent!(team: team) }
  let(:area) { MicroAreaFieldAssignment.active.find_by!(professional_id: agent.professional.id).micro_area }
  let(:device) { FieldDevices::Register.call(user: agent, name: "Tablet").payload.fetch(:device) }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "12") }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def at_now = Time.current.change(usec: 0)
  def item(type, body, uuid: SecureRandom.uuid) = { "client_uuid" => uuid, "type" => type, "body" => body }
  def upload(*items, user: agent, dev: device) = FieldSync::Upload.call(items: items, device: dev, user: user)
  def failure(result) = result.slice("status", "error", "path")

  def valid_response!(results)
    expect(FieldSync::Schemas.errors("upload-response-v1", { "results" => results }.as_json)).to eq([])
  end

  def strategic_point = registry_household!(micro_area: area, property_type: "4")

  def report(**over)
    { "activity" => "pe", "work_type" => "routine", "situation" => "worked", "educational_action" => false,
      "deposits" => [ { "group" => "A2", "existing" => 3, "with_water" => 2, "with_larvae" => 1, "eliminated" => 1, "treated" => 1 } ],
      "measures" => [ { "method" => "mechanical" } ],
      "samples" => [ { "number" => 1, "deposit_group" => "A2", "larvae_collected" => 5 } ] }.merge(over.stringify_keys)
  end

  def visit_body(household = strategic_point, **over)
    { "team_id" => team.id, "occurred_at" => at_now.iso8601, "household_id" => household.id, "subject" => "none", "outcome" => 1,
      "reasons" => [], "shared" => false, "vector_inspection" => report }.merge(over.stringify_keys)
  end

  def installation(household, **over)
    { "household_id" => household.id, "number" => "OVT-015", "consent" => true,
      "installed_on" => (Time.zone.today - 5).iso8601 }.merge(over.stringify_keys)
  end

  def cited_installation(household_uuid)
    { "household_client_uuid" => household_uuid, "number" => "OVT-015", "consent" => true, "installed_on" => (Time.zone.today - 5).iso8601 }
  end

  def gate_off!
    Platform::Features.set!(city: Current.city, key: VectorControl::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
  end

  it "home_visit do ACE com vector_inspection → accepted com vector_inspection_id; reenvio → duplicate com o mesmo vector_inspection_id" do
    uuid = SecureRandom.uuid
    sent = item("home_visit", visit_body, uuid: uuid)
    first = upload(sent).sole
    valid_response!([ first ])
    visit = HomeVisit.sole
    inspection = VectorInspection.sole
    expect(first).to eq("client_uuid" => uuid, "status" => "accepted", "type" => "home_visit", "id" => visit.id,
                        "vector_inspection_id" => inspection.id)
    expect(visit).to have_attributes(origin: "field_app", field_device_id: device.id, reasons: [ 35, 36 ])
    expect(VectorSample.sole.label).to eq("#{uuid[0, 8].upcase}-01")

    again = upload(sent).sole
    valid_response!([ again ])
    expect(again).to eq(first.merge("status" => "duplicate"))
    expect([ HomeVisit.count, VectorInspection.count ]).to eq([ 1, 1 ])
  end

  it "home_visit sem boletim do ACE → accepted sem vector_inspection_id" do
    home = registry_household!(micro_area: area, property_type: "2")
    result = upload(item("home_visit", visit_body(home).except("vector_inspection").merge("outcome" => 3))).sole
    valid_response!([ result ])
    expect(result.keys).to contain_exactly("client_uuid", "status", "type", "id")
    expect(result["status"]).to eq("accepted")
  end

  it "lote ovitrap_installation (household_client_uuid) → ovitrap_collection (ovitrap_client_uuid) → dois accepted com o id da ovitrampa e sem ovitrap_id (Q7(2), Q10)" do
    household_uuid = SecureRandom.uuid
    install_uuid = SecureRandom.uuid
    household = { "micro_area_id" => area.id, "property_type" => "4", "refused" => false, "contact_phone" => "4133334444",
                  "address" => registry_address.merge("neighborhood_id" => neighborhood.id) }
    install = item("ovitrap_installation", cited_installation(household_uuid), uuid: install_uuid)
    collect = { "ovitrap_client_uuid" => install_uuid, "collected_on" => Time.zone.today.iso8601, "condition" => "ok",
                "reinstall" => true, "remove" => false }
    results = upload(item("household", household, uuid: household_uuid), install, item("ovitrap_collection", collect))
    valid_response!(results)
    # O domicílio do lote nasce sem quarteirão no perfil: a instalação recusa.
    expect(results.map { failure(_1) }.drop(1)).to eq([ { "status" => "rejected", "error" => "household_without_block", "path" => "household_id" },
                                                        { "status" => "rejected", "error" => "not_found", "path" => "ovitrap_client_uuid" } ])

    household_id = results[0]["id"]
    vector_profile!(Household.find(household_id), block: block)
    results = upload(install, item("ovitrap_collection", collect))
    valid_response!(results)
    ovitrap = Ovitrap.sole
    expect(results.map { _1.slice("status", "type", "id") }).to eq([ { "status" => "accepted", "type" => "ovitrap_installation", "id" => ovitrap.id },
                                                                    { "status" => "accepted", "type" => "ovitrap_collection", "id" => ovitrap.id } ])
    expect(results.flat_map(&:keys)).not_to include("ovitrap_id", "vector_inspection_id", "version")
    expect(ovitrap).to have_attributes(origin: "field_app", field_device_id: device.id, household_id: household_id,
                                       client_uuid: install_uuid, version: 2)
    expect(ovitrap.readings.order(:installed_on).map { [ _1.installed_on, _1.collected_on, _1.condition ] })
      .to eq([ [ Time.zone.today - 5, Time.zone.today, "ok" ], [ Time.zone.today, nil, nil ] ])
    expect(FieldSyncReceipt.where(item_type: %w[ovitrap_installation ovitrap_collection]).pluck(:result_type, :result_id))
      .to eq([ [ "Ovitrap", ovitrap.id ] ] * 2)

    replay = upload(item("ovitrap_installation", installation(ovitrap.household), uuid: install_uuid)).sole
    valid_response!([ replay ])
    expect(replay).to include("status" => "duplicate", "id" => ovitrap.id)
  end

  it "coleta com remove true e reinstall true → removida, sem leitura nova; com lost → perdida (CV-9)" do
    removed = ovitrap_installed!(agent: agent, household: ovitrap_household!(agent, block: block), number: "OV-1")
    lost = ovitrap_installed!(agent: agent, household: ovitrap_household!(agent, block: block), number: "OV-2")
    body = ->(ovitrap, condition) { { "ovitrap_id" => ovitrap.id, "collected_on" => Time.zone.today.iso8601, "condition" => condition,
                                      "reinstall" => true, "remove" => true } }
    results = upload(item("ovitrap_collection", body.call(removed, "dry")), item("ovitrap_collection", body.call(lost, "lost")))
    valid_response!(results)
    expect(results.map { _1.slice("status", "id") }).to eq([ { "status" => "accepted", "id" => removed.id }, { "status" => "accepted", "id" => lost.id } ])
    expect([ removed.reload.status, removed.removed_on, removed.readings.count ]).to eq([ "removed", Time.zone.today, 1 ])
    expect([ lost.reload.status, lost.readings.open_readings.count ]).to eq([ "lost", 0 ])
  end

  it "coleta com reinstall false sem remove → rejected invalid_request path reinstall (Q33)" do
    ovitrap = ovitrap_installed!(agent: agent, household: ovitrap_household!(agent, block: block), number: "OV-3")
    body = ->(**flags) { { "ovitrap_id" => ovitrap.id, "collected_on" => Time.zone.today.iso8601, "condition" => "ok" }.merge(flags.stringify_keys) }
    results = upload(item("ovitrap_collection", body.call(reinstall: false, remove: false)),
                     item("ovitrap_collection", body.call(reinstall: false)))
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([ { "status" => "rejected", "error" => "invalid_request", "path" => "reinstall" } ] * 2)
    expect(ovitrap.reload).to have_attributes(status: "active", version: 1)
    expect(ovitrap.readings.open_readings.count).to eq(1)
    expect(FieldSyncReceipt.count).to eq(0)
  end

  it "recusas da ovitrampa com os path do contracts (resp_vector_rejected)" do
    household = ovitrap_household!(agent, block: block)
    taken = ovitrap_installed!(agent: agent, household: ovitrap_household!(agent, block: block), number: "OVT-015")
    open = ovitrap_installed!(agent: agent, household: household, number: "OV-9", installed_on: Time.zone.today)
    results = upload(item("ovitrap_installation", installation(household, consent: false)),
                     item("ovitrap_installation", installation(ovitrap_household!(agent))),
                     item("ovitrap_installation", installation(household)),
                     item("ovitrap_collection", { "ovitrap_client_uuid" => SecureRandom.uuid, "collected_on" => Time.zone.today.iso8601,
                                                  "condition" => "ok" }),
                     item("ovitrap_collection", { "ovitrap_id" => open.id, "collected_on" => Time.zone.today.iso8601, "condition" => "ok" }),
                     item("ovitrap_collection", { "ovitrap_id" => SecureRandom.uuid, "collected_on" => Time.zone.today.iso8601, "condition" => "ok" }))
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([
      { "status" => "rejected", "error" => "consent_required", "path" => "consent" },
      { "status" => "rejected", "error" => "household_without_block", "path" => "household_id" },
      { "status" => "rejected", "error" => "ovitrap_number_taken", "path" => "number" },
      { "status" => "rejected", "error" => "not_found", "path" => "ovitrap_client_uuid" },
      { "status" => "rejected", "error" => "collection_out_of_range", "path" => "collected_on" },
      { "status" => "rejected", "error" => "not_found", "path" => "ovitrap_id" }
    ])
    expect(Ovitrap.count).to eq(2)
    expect(taken.reload.version).to eq(1)
    expect(FieldSyncReceipt.count).to eq(0)
  end

  it "duas visitas com etiqueta colidindo → a segunda rejected sample_label_taken path vector_inspection.samples[0] (Q7(1))" do
    prefix = SecureRandom.hex(4)
    results = upload(item("home_visit", visit_body, uuid: "#{prefix}-#{SecureRandom.uuid[9..]}"),
                     item("home_visit", visit_body, uuid: "#{prefix}-#{SecureRandom.uuid[9..]}"))
    valid_response!(results)
    expect(results[0]["status"]).to eq("accepted")
    expect(failure(results[1])).to eq("status" => "rejected", "error" => "sample_label_taken", "path" => "vector_inspection.samples[0]")
    expect([ HomeVisit.count, VectorInspection.count, VectorSample.count ]).to eq([ 1, 1, 1 ])
  end

  it "erro de esquema dentro do boletim → vector_inspection_invalid com o mesmo path (CV-4); boletim sem domicílio → path household_id (CV-6)" do
    without_household = visit_body.except("household_id").merge("micro_area_id" => area.id, "property_type" => "4")
    results = upload(item("home_visit", visit_body(vector_inspection: report(deposits: [ report["deposits"][0].merge("group" => "F") ]))),
                     item("home_visit", visit_body(vector_inspection: nil)),
                     item("home_visit", visit_body(vector_inspection: report.except("situation"))),
                     item("home_visit", visit_body(vector_inspection: report(samples: [ { "number" => 1, "deposit_group" => "A2", "larvae_collected" => 11 } ]))),
                     item("home_visit", visit_body(occurred_at: "2026-11-12T09:40:00")),
                     item("home_visit", without_household))
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([
      { "status" => "rejected", "error" => "vector_inspection_invalid", "path" => "vector_inspection.deposits[0].group" },
      { "status" => "rejected", "error" => "vector_inspection_invalid", "path" => "vector_inspection" },
      { "status" => "rejected", "error" => "vector_inspection_invalid", "path" => "vector_inspection.situation" },
      { "status" => "rejected", "error" => "vector_inspection_invalid", "path" => "vector_inspection.samples[0].larvae_collected" },
      { "status" => "rejected", "error" => "invalid_request", "path" => "occurred_at" },
      { "status" => "rejected", "error" => "vector_inspection_invalid", "path" => "household_id" }
    ])
    expect(HomeVisit.count).to eq(0)
  end

  it "o item household recusa `vector`: só leitura (CV-10)" do
    body = { "micro_area_id" => area.id, "property_type" => "4", "refused" => false, "contact_phone" => "4133334444",
             "address" => registry_address, "vector" => { "city_block_id" => block.id } }
    result = upload(item("household", body)).sole
    valid_response!([ result ])
    expect(failure(result)).to eq("status" => "rejected", "error" => "invalid_request", "path" => "vector")
    expect(HouseholdVectorProfile.count).to eq(0)
  end

  it "ACS instalando ou coletando → cbo_not_allowed" do
    acs = field_agent!(team: team)
    acs_device = FieldDevices::Register.call(user: acs, name: "Celular").payload.fetch(:device)
    ovitrap = ovitrap_installed!(agent: agent, household: ovitrap_household!(agent, block: block))
    results = upload(item("ovitrap_installation", installation(ovitrap.household, number: "OV-77")),
                     item("ovitrap_collection", { "ovitrap_id" => ovitrap.id, "collected_on" => Time.zone.today.iso8601, "condition" => "ok" }),
                     user: acs, dev: acs_device)
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([ { "status" => "rejected", "error" => "cbo_not_allowed" } ] * 2)
    expect(ovitrap.reload.version).to eq(1)
  end

  it "gate desligado: home_visit com vector_inspection → rejected feature_disabled path vector_inspection; itens de ovitrampa → feature_disabled" do
    household = ovitrap_household!(agent, block: block)
    home = strategic_point
    gate_off!
    results = upload(item("home_visit", visit_body(home)), item("ovitrap_installation", installation(household)))
    valid_response!(results)
    expect(results.map { failure(_1) }).to eq([ { "status" => "rejected", "error" => "feature_disabled", "path" => "vector_inspection" },
                                                { "status" => "rejected", "error" => "feature_disabled" } ])
    expect(HomeVisit.count + Ovitrap.count).to eq(0)
  end

  it "envio da v1.2.0 (visita do ACS sem vector_inspection) → accepted como antes (§19)" do
    acs = field_agent!(team: team)
    acs_area = registry_micro_area!(code: "01", team: team, acs: acs)
    acs_device = FieldDevices::Register.call(user: acs, name: "Celular").payload.fetch(:device)
    body = { "team_id" => team.id, "occurred_at" => at_now.iso8601, "micro_area_id" => acs_area.id, "property_type" => "1",
             "subject" => "none", "outcome" => 1, "reasons" => [ 1 ], "shared" => false }
    result = upload(item("home_visit", body), user: acs, dev: acs_device).sole
    valid_response!([ result ])
    expect(result.keys).to contain_exactly("client_uuid", "status", "type", "id")
    expect(result["status"]).to eq("accepted")
    expect(VectorInspection.count).to eq(0)
  end
end
