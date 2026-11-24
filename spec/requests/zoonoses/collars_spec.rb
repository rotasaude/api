require "rails_helper"

# Módulo 35b, Task 14 (ADR 0054; contrato §6, §10): /zoonoses/collars, para
# team? (403 missing_role). POST coloca (troca a ativa); POST /:id/remove
# retira (a segunda vez → 409 collar_changed); GET ?due=1 lista as ativas com
# due_on até hoje + 15 dias, sem tutor.
RSpec.describe "Zoonoses — coleiras", type: :request do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:headers) { { "CONTENT_TYPE" => "application/json" } }
  let(:today) { Time.zone.today }
  let(:product) { zoonoses_product!(use: "collar") }

  def json_post_to(path, fields) = post(path, params: fields.to_json, headers: headers)

  before { sign_in_as(team) }

  it "due=1 traz a de 15 dias e não a de 16; sem tutor; só ativas" do
    tutor = tutor!
    soon = collar!(animal: animal!(tutor: tutor), product: product, placed_on: today - 20, due_on: today + 15)
    late = collar!(animal: animal!(household: nil), product: product, placed_on: today - 200, due_on: today - 5)
    collar!(animal: animal!, product: product, placed_on: today - 20, due_on: today + 16)
    gone = collar!(animal: animal!, product: product, placed_on: today - 200, due_on: today - 1)
    gone.update!(removed_on: today - 1, removal_reason: "lost")
    moved = animal!(status: "transferred", status_on: today)
    collar!(animal: moved, product: product, placed_on: today - 20, due_on: today + 3)

    get "/zoonoses/collars?due=1"
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].pluck("id")).to eq([ late.id, soon.id ])
    expect(json_body["items"].last).to include("animal_id" => soon.animal_id, "household_id" => nil, "due_on" => (today + 15).iso8601)
    expect(response.body).not_to include(tutor.id)
    expect(response.body).not_to include(ZoonosesHelpers::ZOONOSES_TUTOR_NAME)

    get "/zoonoses/collars"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "due" } ])
    get "/zoonoses/collars?due=1&x=1"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "coloca e troca pela rota; remover duas vezes → 409 collar_changed" do
    animal = animal!
    json_post_to("/zoonoses/collars", { animal_id: animal.id, vector_product_id: product.id, placed_on: (today - 10).iso8601 })
    expect(response).to have_http_status(:created)
    first_id = json_body["id"]
    expect(json_body).to include("animal_id" => animal.id, "removed_on" => nil, "due_on" => ((today - 10) >> 6).iso8601)

    json_post_to("/zoonoses/collars", { animal_id: animal.id, vector_product_id: product.id })
    expect(response).to have_http_status(:created)
    expect(Collar.find(first_id)).to have_attributes(removal_reason: "replaced")

    second_id = json_body["id"]
    json_post_to("/zoonoses/collars/#{second_id}/remove", { reason: "lost" })
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => second_id, "removal_reason" => "lost", "removed_on" => today.iso8601)
    json_post_to("/zoonoses/collars/#{second_id}/remove", { reason: "lost" })
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "collar_changed" } ])
    json_post_to("/zoonoses/collars/#{first_id}/remove", { reason: "other" })
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "collar_changed" } ])
  end

  it "recusas: motivo, data, desconhecido, 404, query, gato e papel" do
    collar = collar!(product: product, placed_on: today - 3)
    json_post_to("/zoonoses/collars/#{collar.id}/remove", { reason: "stolen" })
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "reason" } ])
    json_post_to("/zoonoses/collars/#{collar.id}/remove", { reason: "replaced" })
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "reason" } ])
    expect(collar.reload.removed_on).to be_nil
    json_post_to("/zoonoses/collars/#{collar.id}/remove", { reason: "lost", removed_on: (today + 1).iso8601 })
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "date_out_of_range", "path" => "removed_on" } ])
    json_post_to("/zoonoses/collars/#{collar.id}/remove", { reason: "lost", note: "x" })
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "note" } ])
    json_post_to("/zoonoses/collars/#{SecureRandom.uuid}/remove", { reason: "lost" })
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    post "/zoonoses/collars/#{collar.id}/remove?x=1", params: { reason: "lost" }.to_json, headers: headers
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    expect(collar.reload.removed_on).to be_nil

    json_post_to("/zoonoses/collars", { animal_id: animal!(species: "cat").id, vector_product_id: product.id })
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "animal_not_dog" } ])

    sign_in_as(staff_with("adm-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
    get "/zoonoses/collars?due=1"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end
end
