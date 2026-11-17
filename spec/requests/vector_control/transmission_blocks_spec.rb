require "rails_helper"

# Módulo 35a, Task 11 (ADR 0054; contrato §8, §12, §17; Q8, Q9, Q13(6)(9);
# W-3): /vector_control/transmission_blocks, o bloqueio da coordenação. O
# caso sai como doença, data e "caso n"; nunca paciente nem notificação. Só a
# rota do endereço do caso (step-up) traz endereço, e grava a trilha.
RSpec.describe "Vigilância ambiental — bloqueio de transmissão", type: :request do
  let!(:city) { block_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:center) { city_block!(neighborhood: neighborhood, number: "10") }
  let(:neighbor) { city_block!(neighborhood: neighborhood, number: "11") }
  let(:far) { city_block!(neighborhood: neighborhood, number: "30") }
  let(:base) { "/vector_control/transmission_blocks" }

  before { block_neighbors!(center, neighbor) }
  after { Current.reset }

  def confirm!(block, block_ids: [ center.id, neighbor.id ])
    expect(VectorControl::Blocks::Confirm.call(block: block, center_block_id: center.id, block_ids: block_ids, by: coordinator)).to be_ok
    block.reload
  end

  it "confirm sem step-up → 401; vector_lab → 403; de active → 409 invalid_transition path status" do
    block = proposed_case!(patient: block_case_patient!(block: center)).transmission_block
    sign_in_as(coordinator)
    json_post "#{base}/#{block.id}/confirm", center_block_id: center.id, block_ids: [ center.id ]
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
    sign_in_as(vector_lab!)
    json_post "#{base}/#{block.id}/confirm", center_block_id: center.id, block_ids: [ center.id ]
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

    stepped_up!(coordinator)
    json_post "#{base}/#{block.id}/confirm", center_block_id: center.id, block_ids: []
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "block_ids" } ])
    json_post "#{base}/#{block.id}/confirm", center_block_id: SecureRandom.uuid, block_ids: [ center.id ]
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "center_block_id" } ])
    json_post "#{base}/#{block.id}/confirm", center_block_id: center.id, block_ids: [ far.id ], note: "x"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "note" } ])

    json_post "#{base}/#{block.id}/confirm", center_block_id: center.id, block_ids: [ far.id ]
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => block.id, "status" => "active", "center_block" => { "id" => center.id, "number" => "10" })
    expect(json_body["area"]).to eq([ { "id" => center.id, "number" => "10", "suggested" => true },
                                      { "id" => far.id, "number" => "30", "suggested" => false } ])
    expect(json_body["confirmed_at"]).to be_present
    expect(block.reload).to have_attributes(status: "active", confirmed_by_user_id: coordinator.id)
    expect(DomainEvent.where(name: "transmission_block.confirmed").sole.payload)
      .to eq("transmission_block_id" => block.id, "user_id" => coordinator.id)

    json_post "#{base}/#{block.id}/confirm", center_block_id: center.id, block_ids: [ center.id ]
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])
    json_post "#{base}/#{block.id}/dismiss", reason: "Caso descartado pela vigilância"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])

    json_post "#{base}/#{block.id}/close", {}
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "closed")
    expect(json_body["closed_at"]).to be_present
    json_post "#{base}/#{block.id}/close", {}
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])
    expect(DomainEvent.where(name: "transmission_block.closed").sole.payload)
      .to eq("transmission_block_id" => block.id, "user_id" => coordinator.id)
  end

  it "dismiss sem motivo → 422 invalid_request path reason; o motivo nunca sai" do
    block = proposed_case!(patient: block_case_patient!(block: center)).transmission_block
    sign_in_as(coordinator)
    json_post "#{base}/#{block.id}/dismiss", {}
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "reason" } ])
    json_post "#{base}/#{block.id}/dismiss", reason: "   curto   "
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "reason" } ])
    json_post "#{base}/#{block.id}/dismiss", reason: "x" * 501
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "reason" } ])
    json_post "#{base}/#{block.id}/close", {}
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])

    log = capture_log { json_post "#{base}/#{block.id}/dismiss", reason: "Caso descartado pela vigilância" }
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "dismissed")
    expect(response.body).not_to include("descartado")
    expect(log).not_to include("descartado")
    expect(block.reload).to have_attributes(status: "dismissed", dismissed_reason: "Caso descartado pela vigilância")
    expect(DomainEvent.where(name: "transmission_block.dismissed").sole.payload)
      .to eq("transmission_block_id" => block.id, "user_id" => coordinator.id)
  end

  it "mover o caso 2 para outro bloqueio → continua number: 2; para bloqueio closed → 409 invalid_transition" do
    first = proposed_case!(patient: block_case_patient!(block: center))
    second = proposed_case!(patient: block_case_patient!(block: neighbor))
    third = proposed_case!(patient: block_case_patient!(block: far))
    other = third.transmission_block
    expect(second).to have_attributes(number: 2, transmission_block_id: first.transmission_block_id)

    sign_in_as(coordinator)
    json_post "#{base}/#{first.transmission_block_id}/cases/#{second.id}/move", to_transmission_block_id: other.id
    expect(response).to have_http_status(:ok)
    expect(json_body["id"]).to eq(other.id)
    expect(json_body["cases"].map { |row| [ row["id"], row["number"] ] }).to eq([ [ second.id, 2 ], [ third.id, 3 ] ])
    expect(second.reload).to have_attributes(number: 2, transmission_block_id: other.id, added_by: "job")

    json_post "#{base}/#{first.transmission_block_id}/cases/#{second.id}/move", to_transmission_block_id: other.id
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    json_post "#{base}/#{other.id}/cases/#{second.id}/move", to_transmission_block_id: other.id
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "to_transmission_block_id" } ])
    json_post "#{base}/#{other.id}/cases/#{second.id}/move", to_transmission_block_id: SecureRandom.uuid
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "to_transmission_block_id" } ])

    closed = confirm!(first.transmission_block)
    expect(VectorControl::Blocks::Close.call(block: closed, by: coordinator)).to be_ok
    json_post "#{base}/#{other.id}/cases/#{second.id}/move", to_transmission_block_id: closed.id
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])
    expect(second.reload.transmission_block_id).to eq(other.id)
  end

  it "lista e detalhe sem nome, CPF, CNS, endereço nem notification_id; has_place: false no caso sem quarteirão" do
    patient = block_case_patient!(block: center)
    placed = proposed_case!(patient: patient)
    unplaced_patient = registry_patient!
    unplaced = proposed_case!(patient: unplaced_patient)
    confirm!(placed.transmission_block)
    VectorControl::Blocks::AddCycle.call(block: placed.transmission_block, starts_on: Date.current.iso8601,
                                         ends_on: (Date.current + 2).iso8601, by: coordinator)

    sign_in_as(vector_lab!)
    get base
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

    sign_in_as(coordinator)
    get base, params: { status: %w[active] }
    expect(response).to have_http_status(:ok)
    expect(json_body["next_before"]).to be_nil
    item = json_body["items"].sole
    expect(item.keys).to match_array(%w[id status disease_group center_block area cases cycles created_at confirmed_at closed_at])
    expect(item).to include("id" => placed.transmission_block_id, "status" => "active", "disease_group" => "arbovirus",
                            "cycles" => [ { "number" => 1, "starts_on" => Date.current.iso8601, "ends_on" => (Date.current + 2).iso8601 } ],
                            "closed_at" => nil)
    expect(item["cases"]).to eq([ { "id" => placed.id, "number" => 1, "disease" => "dengue",
                                    "case_on" => placed.case_on.iso8601, "has_place" => true } ])

    get base, params: { status: %w[proposed] }
    expect(json_body["items"].sole).to include("id" => unplaced.transmission_block_id, "center_block" => nil, "area" => [],
                                               "cases" => [ hash_including("number" => 2, "has_place" => false) ])
    get base
    expect(json_body["items"].map { |row| row["id"] }).to eq([ unplaced.transmission_block_id, placed.transmission_block_id ])
    get base, params: { status: %w[open] }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "status" } ])
    get base, params: { q: "x" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])

    bodies = []
    get base
    bodies << response.body
    [ placed, unplaced ].each do |row|
      get "#{base}/#{row.transmission_block_id}"
      expect(response).to have_http_status(:ok)
      bodies << response.body
    end
    get "#{base}/#{SecureRandom.uuid}"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])

    household = IndividualRegistration.find_by!(patient_id: patient.id).household
    secrets = [ patient.full_name, patient.cpf, patient.cns, unplaced_patient.full_name, unplaced_patient.cpf,
                "das Flores", HomeVisits::Json.addresses([ household.id ]).fetch(household.id),
                placed.disease_notification_id, unplaced.disease_notification_id, patient.id, unplaced_patient.id ].compact
    bodies.each do |body|
      secrets.each { |secret| expect(body).not_to include(secret) }
      keys = JSON.parse(body).to_s
      %w[patient notification_id full_name cpf cns address phone latitude longitude].each { |key| expect(keys).not_to include("\"#{key}") }
    end
  end

  it "address com step-up grava clinical_record.viewed com access transmission_block_case; vector_lab → 403" do
    patient = block_case_patient!(block: center)
    patient.update!(address_street: "Rua das Palmeiras", address_number: "45", address_district: "Centro")
    row = proposed_case!(patient: patient)
    path = "#{base}/#{row.transmission_block_id}/cases/#{row.id}/address"

    sign_in_as(coordinator)
    get path
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
    stepped_up!(vector_lab!)
    get path
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    expect(DomainEvent.where(name: "clinical_record.viewed").where("payload->>'access' = ?", "transmission_block_case")).to be_empty

    stepped_up!(coordinator)
    get path, params: { x: 1 }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    get "#{base}/#{row.transmission_block_id}/cases/#{SecureRandom.uuid}/address"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])

    get path
    expect(response).to have_http_status(:ok)
    household = IndividualRegistration.find_by!(patient_id: patient.id).household
    expect(json_body).to eq("patient_address" => "Rua das Palmeiras, 45, Centro",
                            "household_address" => HomeVisits::Json.addresses([ household.id ]).fetch(household.id))
    trail = DomainEvent.where(name: "clinical_record.viewed").where("payload->>'access' = ?", "transmission_block_case").sole
    expect(trail.payload).to eq("patient_id" => patient.id, "user_id" => coordinator.id, "access" => "transmission_block_case",
                                "reason_code" => nil, "person_ref" => "patient:#{patient.id}",
                                "transmission_block_id" => row.transmission_block_id)
    expect(DomainEvent.where(name: "transmission_block_case.address_viewed").sole.payload)
      .to eq("transmission_block_id" => row.transmission_block_id, "user_id" => coordinator.id)
  end
end
