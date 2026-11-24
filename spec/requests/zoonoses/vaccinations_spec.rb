require "rails_helper"

# Módulo 35b, Task 7 (ADR 0054; contrato §3, §10, §16): /zoonoses/vaccinations,
# para team? (403 missing_role). POST registra (Zoonoses::RecordVaccination, o
# gate de campo lido no controller, fora da transação); com evento adverso, a
# resposta traz o lembrete fixo (EATAV). POST /:id/cancel anula com o motivo.
# GET lista paginada, filtrada por campanha, período e modalidade, sem tutor
# nem nome do animal, nem nota.
RSpec.describe "Zoonoses — vacinação", type: :request do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:headers) { { "CONTENT_TYPE" => "application/json" } }
  let(:today) { Time.zone.today }
  let(:vaccine) { zoonoses_product! }
  let(:campaign) do
    RabiesCampaign.create!(name: "Campanha #{SecureRandom.hex(3)}", year: today.year, starts_on: today - 20, ends_on: today + 20,
                           goal_dogs: 10, goal_cats: 5, stage: "open")
  end

  def body(**over)
    { modality: "fixed_post", campaign_id: campaign.id, species: "dog", vaccinated_on: today.iso8601, vector_product_id: vaccine.id,
      adverse_event: false }.merge(over).reject { |_, value| value == :omit }
  end

  def vaccinate(fields = body, query: "") = post("/zoonoses/vaccinations#{query}", params: fields.to_json, headers: headers)
  def list(query = "") = get("/zoonoses/vaccinations#{query}")

  before { sign_in_as(team) }

  it "a resposta do evento adverso traz o lembrete fixo; sem evento, sem lembrete; a nota nunca volta" do
    vaccinate(body(adverse_event: true, adverse_note: "Edema local no ponto da aplicação"))
    expect(response).to have_http_status(:created)
    expect(json_body).to include("modality" => "fixed_post", "species" => "dog", "campaign_id" => campaign.id, "adverse_event" => true,
                                 "cancelled" => false, "stock_lot_id" => nil,
                                 "reminder" => "Notifique o evento adverso no formulário do Ministério da Saúde (EATAV).")
    expect(response.body).not_to include("Edema")

    vaccinate
    expect(response).to have_http_status(:created)
    expect(json_body).not_to have_key("reminder")
  end

  it "recusas { error, path }: 422, 409 e 403; query no POST → 422" do
    animal = animal!
    vaccinate(body(species: :omit, animal_id: animal.id))
    vaccinate(body(species: :omit, animal_id: animal.id))
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "already_vaccinated_in_campaign" } ])
    vaccinate(body(vaccinated_on: (today - 21).iso8601))
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "date_out_of_range", "path" => "vaccinated_on" } ])
    vaccinate(body(species: :omit, animal_id: animal!(status: "missing", status_on: today).id))
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "animal_not_active" } ])
    vaccinate(body, query: "?species=dog")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])

    sign_in_as(staff_with("estoque-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"))
    vaccinate
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "casa a casa pelo dashboard: gate de campo desligado → 403 feature_disabled com feature home_visits; ligado → 201 com o domicílio do animal" do
    household = registry_household!
    animal = animal!(household: household)
    Platform::Features.set!(city: city, key: HomeVisits::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    expect(Zoonoses::Gate.usable?(city)).to be(true)
    vaccinate(body(modality: "house", species: :omit, animal_id: animal.id))
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "home_visits" } ])

    Platform::Features.set!(city: city, key: HomeVisits::Gate::KEY, enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    vaccinate(body(modality: "house", species: :omit, animal_id: animal.id))
    expect(response).to have_http_status(:created)
    expect(json_body).to include("modality" => "house", "household_id" => household.id, "animal_id" => animal.id)
  end

  it "lista filtrada por modalidade, sem tutor nem nome" do
    tutor = tutor!
    named = animal!(name: "Bidu Marcado", tutor: tutor, household: registry_household!)
    vaccinate(body(species: :omit, animal_id: named.id))
    post_id = json_body["id"]
    vaccinate(body(modality: "routine", campaign_id: :omit, species: :omit, animal_id: named.id))
    routine_id = json_body["id"]

    list("?modality=fixed_post")
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].pluck("id")).to eq([ post_id ])
    expect(json_body).to include("next_before" => nil)
    list("?modality=routine")
    expect(json_body["items"].pluck("id")).to eq([ routine_id ])
    list
    expect(json_body["items"].pluck("id")).to contain_exactly(post_id, routine_id)
    item = json_body["items"].first
    expect(item.keys).to match_array(%w[id modality campaign_id animal_id species vaccinated_on health_unit_id household_id
                                        vector_product_id stock_lot_id adverse_event cancelled cancelled_at recorded_by_user_id created_at])
    [ "Bidu Marcado", ZoonosesHelpers::ZOONOSES_TUTOR_NAME, tutor.id ].each { |text| expect(response.body).not_to include(text) }

    list("?modality=boat")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "modality" } ])
    list("?tutor_patient_id=#{tutor.id}")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "lista por campanha e período; paginada por before e limit" do
    other = RabiesCampaign.create!(name: "Velha", year: today.year, starts_on: today - 90, ends_on: today - 60, goal_dogs: 1,
                                   goal_cats: 1, stage: "closed")
    old = rabies_vaccination!(animal: nil, species: "dog", modality: "fixed_post", campaign: other, vaccinated_on: today - 70,
                              product: vaccine)
    ids = Array.new(3) do |i|
      vaccinate(body(vaccinated_on: (today - i).iso8601))
      json_body["id"]
    end

    list("?campaign_id=#{other.id}")
    expect(json_body["items"].pluck("id")).to eq([ old.id ])
    list("?from=#{(today - 1).iso8601}&to=#{today.iso8601}")
    expect(json_body["items"].pluck("id")).to contain_exactly(ids[0], ids[1])
    list("?from=2026-13-01")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "from" } ])

    list("?campaign_id=#{campaign.id}&limit=2")
    first_page = json_body["items"].pluck("id")
    expect(first_page.size).to eq(2)
    list("?campaign_id=#{campaign.id}&limit=2&before=#{CGI.escape(json_body['next_before'])}")
    expect((first_page + json_body["items"].pluck("id"))).to match_array(ids)
    expect(json_body["next_before"]).to be_nil
  end

  it "POST /:id/cancel anula com o motivo; outro da equipe → 403; segunda → 409; corpo extra → 422" do
    vaccinate
    id = json_body["id"]
    sign_in_as(zoonoses_team!)
    post "/zoonoses/vaccinations/#{id}/cancel", params: { reason: "Dose lançada no animal errado" }.to_json, headers: headers
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

    sign_in_as(team)
    post "/zoonoses/vaccinations/#{id}/cancel", params: { reason: "Dose lançada no animal errado", force: true }.to_json, headers: headers
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "force" } ])
    post "/zoonoses/vaccinations/#{id}/cancel", params: { reason: "Dose lançada no animal errado" }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => id, "cancelled" => true)
    expect(response.body).not_to include("errado")
    post "/zoonoses/vaccinations/#{id}/cancel", params: { reason: "Dose lançada no animal errado" }.to_json, headers: headers
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])
    post "/zoonoses/vaccinations/#{SecureRandom.uuid}/cancel", params: { reason: "Dose lançada no animal errado" }.to_json, headers: headers
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end
end
