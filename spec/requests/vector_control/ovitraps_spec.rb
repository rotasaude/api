require "rails_helper"

# Módulo 35a, Task 9 (ADR 0054; contrato §6, §12; Q7(2), Q8, Q9, Q13(2)):
# /vector_control/ovitraps e /vector_control/ovitrap_readings. O agente
# instala e coleta (a resposta é a Ovitrap); a coordenação e o vector_lab
# contam. A lista sai por microárea (agente, no escopo) ou por bairro
# (coordenação e laboratório), com o endereço curto do 24a e a trilha
# territory_registry, nunca morador.
RSpec.describe "Vigilância ambiental — ovitrampas", type: :request do
  let!(:city) { vector_city! }
  let(:agent) { endemic_agent! }
  let(:area) { MicroAreaFieldAssignment.active.find_by!(professional: agent.professional).micro_area }
  let(:lab) { vector_lab! }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "12") }
  let(:household) { ovitrap_household!(agent, block: block) }
  let(:today) { Time.zone.today }

  def trails = DomainEvent.where(name: "clinical_record.viewed")

  def install_body(**over)
    { client_uuid: SecureRandom.uuid, household_id: household.id, number: "OV-12", consent: true,
      installed_on: (today - 5).iso8601 }.merge(over)
  end

  it "ACE instala e coleta; vector_lab conta; ACE contando → 403 missing_role" do
    sign_in_as(agent)
    body = install_body
    json_post "/vector_control/ovitraps", body
    expect(response).to have_http_status(:created)
    ovitrap = Ovitrap.sole
    reading = ovitrap.readings.sole
    expect(json_body).to eq("id" => ovitrap.id, "number" => "OV-12", "household" => { "id" => household.id, "address_short" => "Rua das Flores, 120" },
                            "city_block" => { "id" => block.id, "number" => "12" }, "status" => "active",
                            "installed_on" => (today - 5).iso8601, "removed_on" => nil,
                            "open_reading" => { "id" => reading.id, "installed_on" => (today - 5).iso8601 }, "last_reading" => nil,
                            "version" => 1)
    json_post "/vector_control/ovitraps", body
    expect([ response.status, json_body["id"] ]).to eq([ 200, ovitrap.id ])

    json_post "/vector_control/ovitraps/#{ovitrap.id}/collect", collected_on: today.iso8601, condition: "ok", reinstall: true, remove: false
    expect(response).to have_http_status(:ok)
    week = Surveillance::EpiWeek.for(today - 5).to_s
    expect(json_body).to include("id" => ovitrap.id, "version" => 2,
                                 "last_reading" => { "id" => reading.id, "collected_on" => today.iso8601, "condition" => "ok",
                                                     "egg_count" => nil, "epi_week" => week })
    expect(json_body["open_reading"]).to include("installed_on" => today.iso8601)

    json_post "/vector_control/ovitrap_readings/#{reading.id}/count", egg_count: 3
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    get "/vector_control/ovitrap_readings", params: { state: "to_count" }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

    sign_in_as(lab)
    get "/vector_control/ovitrap_readings", params: { state: "to_count" }
    expect(json_body).to eq("items" => [ { "id" => reading.id, "ovitrap" => { "id" => ovitrap.id, "number" => "OV-12" },
                                           "city_block" => { "id" => block.id, "number" => "12" },
                                           "neighborhood" => { "id" => neighborhood.id, "name" => neighborhood.name },
                                           "installed_on" => (today - 5).iso8601, "collected_on" => today.iso8601, "condition" => "ok",
                                           "epi_week" => week, "egg_count" => nil, "counted_at" => nil, "corrected" => false } ],
                            "next_before" => nil)
    json_post "/vector_control/ovitrap_readings/#{reading.id}/count", egg_count: 0
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => reading.id, "egg_count" => 0, "corrected" => false)
    expect(json_body["counted_at"]).to be_present
    json_post "/vector_control/ovitrap_readings/#{reading.id}/count", egg_count: 4
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "count_note" } ])
    json_post "/vector_control/ovitrap_readings/#{reading.id}/count", egg_count: 4, count_note: "Recontagem com lupa estereoscópica"
    expect(json_body).to include("egg_count" => 4, "corrected" => true)
    expect(json_body.to_s).not_to include("lupa")

    get "/vector_control/ovitrap_readings", params: { state: "to_count" }
    expect(json_body["items"]).to be_empty
    get "/vector_control/ovitrap_readings", params: { state: "counted" }
    expect(json_body["items"].map { |item| item["id"] }).to eq([ reading.id ])
    get "/vector_control/ovitrap_readings", params: { state: "open" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "state" } ])
  end

  it "recusas da instalação e da coleta saem só com error e path" do
    sign_in_as(agent)
    json_post "/vector_control/ovitraps", install_body(consent: false)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "consent_required", "path" => "consent" } ])
    json_post "/vector_control/ovitraps", install_body(number: "OV 12")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "number" } ])
    body = install_body
    json_post "/vector_control/ovitraps", body
    ovitrap_id = json_body["id"]
    json_post "/vector_control/ovitraps", install_body
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "ovitrap_number_taken", "path" => "number" } ])

    json_post "/vector_control/ovitraps/#{ovitrap_id}/collect", collected_on: (today - 3).iso8601, condition: "ok"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "collection_out_of_range", "path" => "collected_on" } ])
    json_post "/vector_control/ovitraps/#{SecureRandom.uuid}/collect", collected_on: today.iso8601, condition: "ok"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    json_post "/vector_control/ovitraps/#{ovitrap_id}/collect?condition=ok", collected_on: today.iso8601, condition: "ok"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])

    sign_in_as(endemic_agent!)
    json_post "/vector_control/ovitraps", body
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "client_uuid_conflict", "path" => "client_uuid" } ])
  end

  it "coleta: reinstall false sem remove → 422 path reinstall; sem as chaves reinstala; remove tira, com reinstall true também (Q33, CV-9)" do
    ovitrap = ovitrap_installed!(agent: agent, household: household, number: "OV-1")
    gone = ovitrap_installed!(agent: agent, household: household, number: "OV-2")
    both = ovitrap_installed!(agent: agent, household: household, number: "OV-3")
    sign_in_as(agent)
    collect = ->(target, **flags) { json_post "/vector_control/ovitraps/#{target.id}/collect", { collected_on: today.iso8601, condition: "ok" }.merge(flags) }

    [ { reinstall: false, remove: false }, { reinstall: false } ].each do |flags|
      collect.call(ovitrap, **flags)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "reinstall" } ])
    end
    expect(ovitrap.reload.version).to eq(1)

    collect.call(ovitrap)
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "active", "version" => 2)
    expect(json_body["open_reading"]).to include("installed_on" => today.iso8601)

    collect.call(gone, remove: true)
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "removed", "removed_on" => today.iso8601, "open_reading" => nil)

    collect.call(both, reinstall: true, remove: true)
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "removed", "removed_on" => today.iso8601, "open_reading" => nil)
  end

  it "a lista não traz morador" do
    first = ovitrap_installed!(agent: agent, household: household, number: "OV-1")
    second = ovitrap_installed!(agent: agent, household: household, number: "OV-2")
    ovitrap_collected!(second, agent: agent, remove: true)
    sign_in_as(agent)

    get "/vector_control/ovitraps", params: { micro_area_id: area.id }
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].map { |item| item["id"] }).to eq([ second.id, first.id ])
    expect(json_body["items"].first.keys).to eq(%w[id number household city_block status installed_on removed_on open_reading last_reading version])
    expect(json_body["items"].first["household"]).to eq("id" => household.id, "address_short" => "Rua das Flores, 120")
    text = response.body
    expect(text).not_to include("4133334444")
    expect(trails.sole.payload).to eq("access" => "territory_registry", "micro_area_id" => area.id,
                                      "household_ids" => [ household.id ], "user_id" => agent.id)

    get "/vector_control/ovitraps", params: { micro_area_id: area.id, status: "active" }
    expect(json_body["items"].map { |item| item["id"] }).to eq([ first.id ])
    get "/vector_control/ovitraps", params: { micro_area_id: area.id, status: "gone" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "status" } ])
    get "/vector_control/ovitraps", params: { micro_area_id: area.id, name: "Maria" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "agente com micro_area_id não atribuída → 403 out_of_scope; vector_lab por neighborhood_id → 200" do
    ovitrap = ovitrap_installed!(agent: agent, household: household)
    other_area = registry_micro_area!(code: "05", team: area.team)

    sign_in_as(agent)
    get "/vector_control/ovitraps", params: { micro_area_id: other_area.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "out_of_scope" } ])
    get "/vector_control/ovitraps", params: { neighborhood_id: neighborhood.id }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    get "/vector_control/ovitraps"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "micro_area_id" } ])

    sign_in_as(lab)
    get "/vector_control/ovitraps", params: { neighborhood_id: neighborhood.id }
    expect(response).to have_http_status(:ok)
    expect(json_body).to match("items" => [ hash_including("id" => ovitrap.id) ], "next_before" => nil)
    get "/vector_control/ovitraps", params: { neighborhood_id: Neighborhood.create!(name: "Vazio #{SecureRandom.hex(2)}", source: "manual").id }
    expect(json_body["items"]).to be_empty
    get "/vector_control/ovitraps", params: { neighborhood_id: SecureRandom.uuid }
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    json_post "/vector_control/ovitraps", install_body
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end
end
