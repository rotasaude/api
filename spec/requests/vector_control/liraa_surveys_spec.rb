require "rails_helper"

# Módulo 35a, Task 10 (ADR 0054; contrato §7, §12, §17; Q8, Q9): o LIRAa da
# coordenação pelas rotas. Draw e close com step-up; o levantamento nas
# formas LiraaSurvey/LiraaStratum e os itens em LiraaItem (endereço curto e
# trilha, nunca morador); recusas só com error e path.
RSpec.describe "Vigilância ambiental — LIRAa", type: :request do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:area) { registry_micro_area!(code: "06") }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "1") }
  let(:other_block) { city_block!(neighborhood: neighborhood, number: "2") }
  let(:today) { Time.zone.today }

  def body(**over)
    { name: "LIRAa janeiro", starts_on: today.iso8601, ends_on: (today + 6).iso8601 }.merge(over)
  end

  def stratum(mode: "census", blocks: [ block ], name: "Estrato 1") = { name: name, mode: mode, block_ids: blocks.map(&:id) }

  it "cria, edita estratos, sorteia e fecha; draw e close sem step-up → 401" do
    homes = liraa_households!(block, 3, micro_area: area)
    sign_in_as(coordinator)

    json_post "/vector_control/liraa_surveys", body
    expect(response).to have_http_status(:created)
    survey = json_body
    expect(survey).to eq("id" => survey["id"], "name" => "LIRAa janeiro", "starts_on" => today.iso8601, "ends_on" => (today + 6).iso8601,
                         "status" => "draft", "parameters_version" => nil, "drawn_at" => nil, "closed_at" => nil, "strata" => [])

    json_patch "/vector_control/liraa_surveys/#{survey['id']}", strata: [ stratum ]
    expect(response).to have_http_status(:ok)
    expect(json_body["strata"].sole.except("id")).to eq("name" => "Estrato 1", "mode" => "census", "block_ids" => [ block.id ],
                                                       "households_count" => nil, "sample_target" => nil, "block_interval" => nil,
                                                       "random_start" => nil)

    json_post "/vector_control/liraa_surveys/#{survey['id']}/draw", {}
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
    json_post "/vector_control/liraa_surveys/#{survey['id']}/close", {}
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])

    stepped_up!(coordinator)
    json_post "/vector_control/liraa_surveys/#{survey['id']}/close", {}
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])

    json_post "/vector_control/liraa_surveys/#{survey['id']}/draw", {}
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "drawn", "parameters_version" => 0)
    expect(json_body["strata"].sole).to include("households_count" => 3, "sample_target" => 3, "block_interval" => 1, "random_start" => 1)

    json_patch "/vector_control/liraa_surveys/#{survey['id']}", name: "Outro"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "survey_not_draft" } ])
    json_post "/vector_control/liraa_surveys/#{survey['id']}/draw", {}
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "survey_not_draft" } ])

    events = []
    allow(DomainEvents).to receive(:publish).and_wrap_original { |m, *args, **kw| events << [ args.first, kw ]; m.call(*args, **kw) }
    get "/vector_control/liraa_surveys/#{survey['id']}/items"
    expect(response).to have_http_status(:ok)
    expect(json_body["next_before"]).to be_nil
    expect(json_body["items"].map { |item| item["household"]["id"] }).to eq(homes.map(&:id))
    expect(json_body["items"].first.keys).to eq(%w[id stratum_id city_block household position status substitute_of_id])
    expect(json_body["items"].first).to include("city_block" => { "id" => block.id, "number" => "1" }, "position" => 1, "status" => "pending",
                                                "substitute_of_id" => nil)
    expect(json_body["items"].first["household"].keys).to eq(%w[id address_short])
    trail = events.select { |name, _| name == "clinical_record.viewed" }
    expect(trail.map { |_, payload| payload.slice(:micro_area_id, :household_ids) })
      .to eq([ { micro_area_id: area.id, household_ids: homes.map(&:id) } ])

    json_post "/vector_control/liraa_surveys/#{survey['id']}/close", {}
    expect(response).to have_http_status(:ok)
    expect(json_body["status"]).to eq("closed")
    expect(json_body["closed_at"]).to be_present
    expect(events.map(&:first)).to include("liraa_survey.closed")

    get "/vector_control/liraa_surveys"
    expect(json_body["items"].map { |row| row["id"] }).to eq([ survey["id"] ])
  end

  it "recusas: quarteirão em dois estratos, estrato fora da faixa, chave desconhecida, outro papel" do
    liraa_households!(block, 2, micro_area: area)
    sign_in_as(coordinator)

    json_post "/vector_control/liraa_surveys", body(strata: [ stratum, stratum(blocks: [ other_block, block ], name: "Estrato 2") ])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "stratum_overlap", "path" => "strata[1].block_ids[1]" } ])
    json_post "/vector_control/liraa_surveys", body(owner: "x")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "owner" } ])
    json_post "/vector_control/liraa_surveys", body(ends_on: (today - 1).iso8601)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "ends_on" } ])
    json_post "/vector_control/liraa_surveys", body(strata: [ stratum(blocks: [ block ]).merge(block_ids: [ SecureRandom.uuid ]) ])
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "strata[0].block_ids[0]" } ])
    expect(LiraaSurvey.count).to eq(0)

    json_post "/vector_control/liraa_surveys", body(strata: [ stratum(mode: "standard") ])
    id = json_body["id"]
    stepped_up!(coordinator)
    json_post "/vector_control/liraa_surveys/#{id}/draw", {}
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "stratum_out_of_range", "path" => "strata[0]" } ])
    expect(LiraaSurvey.find(id).status).to eq("draft")

    sign_in_as(vector_lab!)
    get "/vector_control/liraa_surveys"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "PATCH troca a lista de estratos na ordem dada; 404 de id desconhecido" do
    sign_in_as(coordinator)
    json_post "/vector_control/liraa_surveys", body(strata: [ stratum ])
    id = json_body["id"]

    json_patch "/vector_control/liraa_surveys/#{id}", strata: [ stratum(blocks: [ other_block ], name: "B"), stratum(mode: "half", name: "A") ]
    expect(json_body["strata"].map { |row| [ row["name"], row["mode"], row["block_ids"] ] })
      .to eq([ [ "B", "census", [ other_block.id ] ], [ "A", "half", [ block.id ] ] ])
    expect(LiraaStratum.where(liraa_survey_id: id).count).to eq(2)

    json_patch "/vector_control/liraa_surveys/#{SecureRandom.uuid}", name: "x"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end
end
