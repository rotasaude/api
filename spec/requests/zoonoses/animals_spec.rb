require "rails_helper"

# Módulo 35b, Task 5 (ADR 0054; contrato §2, §10, §16, Q2, Q12, Q26, Q30,
# Q31): /zoonoses/animals. team? (zoonoses_team, a coordenação; a veterinária
# precisa do papel, Q12/Q30). Busca só pelo corpo (microchip nunca em URL);
# lista sem tutor; detalhe com o tutor { id, display_name }, has_microchip e
# o histórico montado por consulta (Q2), com a trilha animal.viewed quando há
# tutor (Q26). Edição com expected_version e as transições da Q31.
RSpec.describe "Zoonoses — animais", type: :request do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:headers) { { "CONTENT_TYPE" => "application/json" } }
  let(:microchip) { "985112345678903" }

  def create_animal(body) = post("/zoonoses/animals", params: body.to_json, headers: headers)
  def search(body = {}, query: "", **fields) = post("/zoonoses/animals/search#{query}", params: body.merge(fields).to_json, headers: headers)
  def edit(animal, body) = patch("/zoonoses/animals/#{animal.id}", params: body.to_json, headers: headers)
  def viewed = DomainEvent.where(name: "animal.viewed").order(:created_at, :id).map(&:payload)

  before { sign_in_as(team) }

  it "zoonoses desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: Zoonoses::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    create_animal(species: "dog", sex: "male")
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "zoonoses" } ])
    get "/zoonoses/animals/#{animal!.id}"
    expect(response).to have_http_status(:forbidden)
  end

  it "stock_keeper → 403 missing_role; perfil 223305/CRMV sem zoonoses_team → 403 missing_role" do
    sign_in_as(staff_with("estoque-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"))
    create_animal(species: "dog", sex: "male")
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

    profile_only = veterinarian!
    profile_only.memberships.where(role: Zoonoses::Catalog::ROLE).update_all(revoked_at: Time.current)
    expect(profile_only.professional.links.active.pluck(:cbo_code)).to eq([ Zoonoses::Catalog::VETERINARIAN_CBO ])
    sign_in_as(profile_only)
    create_animal(species: "dog", sex: "male")
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    expect(Animal.count).to eq(0)
  end

  it "veterinária com zoonoses_team e perfil → 201; coordenação → 201" do
    [ veterinarian!, zoonoses_coordinator! ].each do |user|
      sign_in_as(user)
      create_animal(species: "cat", sex: "unknown")
      expect(response).to have_http_status(:created)
    end
  end

  it "POST cria: 201 com o animal, sem o número do microchip; recusa { error, path }; query → 422" do
    create_animal(species: "dog", sex: "female", name: "Bidu", microchip: microchip, birth_estimate_on: "2025-03")
    expect(response).to have_http_status(:created)
    expect(json_body).to include("species" => "dog", "sex" => "female", "name" => "Bidu", "has_microchip" => true,
                                 "birth_estimate_on" => "2025-03-01", "status" => "active", "version" => 1, "has_tutor" => false)
    expect(response.body).not_to include(microchip)
    create_animal(species: "dog", sex: "female", microchip: microchip)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "microchip_taken", "path" => "microchip" } ])
    post "/zoonoses/animals?species=dog", params: { species: "dog", sex: "male" }.to_json, headers: headers
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "busca por microchip no corpo → 1 item; registro → 1 item; GET /zoonoses/animals/search?microchip= → 404 ou 422, nada lido da URL" do
    animal = animal!(microchip: microchip, registry_number: "UVZ-9")
    search(microchip: microchip)
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].pluck("id")).to eq([ animal.id ])
    expect(response.body).not_to include(microchip)
    search(registry_number: "uvz-9")
    expect(json_body["items"].pluck("id")).to eq([ animal.id ])
    search(microchip: "985112345678904")
    expect(json_body).to eq("items" => [])

    get "/zoonoses/animals/search?microchip=#{microchip}"
    expect([ 404, 422 ]).to include(response.status)
    expect(response.body).not_to include(animal.id)
    search({ microchip: microchip }, query: "?microchip=#{microchip}")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "busca: dois critérios → path do segundo; nenhum → path microchip; microchip malformado → path microchip" do
    household = registry_household!
    search(microchip: microchip, household_id: household.id)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "household_id" } ])
    search({})
    expect(json_body).to eq("error" => "invalid_request", "path" => "microchip")
    search(microchip: "123")
    expect(json_body).to eq("error" => "invalid_request", "path" => "microchip")
    search(tutor_patient_id: "nao-uuid")
    expect(json_body).to eq("error" => "invalid_request", "path" => "tutor_patient_id")
  end

  it "busca por domicílio pagina com next_before e sem tutor nas linhas; por tutor também" do
    household = registry_household!
    tutor = tutor!
    animals = Array.new(52) { |i| animal!(household: household, tutor: (tutor if i.even?), name: "Cão #{i}") }
    animal!(household: registry_household!)
    search(household_id: household.id)
    expect(response).to have_http_status(:ok)
    first = json_body
    expect(first["items"].size).to eq(50)
    expect(first["next_before"]).to be_present
    expect(first["items"].first.keys).not_to include("tutor", "tutor_patient_id")
    expect(first["items"].first).to include("has_tutor", "community")
    expect(response.body).not_to include(tutor.id, ZoonosesHelpers::ZOONOSES_TUTOR_NAME)
    search(household_id: household.id, before: first["next_before"])
    rest = json_body
    expect(rest["next_before"]).to be_nil
    expect((first["items"] + rest["items"]).pluck("id")).to match_array(animals.map(&:id))
    search(household_id: household.id, before: "lixo")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cursor" } ])

    search(tutor_patient_id: tutor.id)
    expect(json_body["items"].size).to eq(26)
    expect(viewed).to be_empty
  end

  it "detalhe com tutor publica animal.viewed só com animal_id e user_id; sem tutor não publica" do
    tutor = tutor!
    with_tutor = animal!(tutor: tutor)
    get "/zoonoses/animals/#{with_tutor.id}"
    expect(response).to have_http_status(:ok)
    expect(json_body["tutor"]).to eq("id" => tutor.id, "display_name" => tutor.display_name)
    expect(viewed).to eq([ { "animal_id" => with_tutor.id, "user_id" => team.id } ])

    get "/zoonoses/animals/#{animal!.id}"
    expect(json_body["tutor"]).to be_nil
    expect(viewed.size).to eq(1)
    get "/zoonoses/animals/#{with_tutor.id}?x=1"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    get "/zoonoses/animals/#{SecureRandom.uuid}"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end

  it "detalhe nunca traz o número do microchip; traz o histórico montado por consulta (Q2)" do
    vet = veterinarian!
    animal = animal!(microchip: microchip)
    stay = shelter_stay!(animal: animal)
    Neutering.create!(animal: animal, performed_on: Time.zone.today - 1, professional: vet.professional, shelter_stay: stay)
    euthanasia = euthanasia!(animal: animal, by: vet, shelter_stay: stay)
    get "/zoonoses/animals/#{animal.id}"
    expect(response).to have_http_status(:ok)
    body = json_body
    expect(response.body).not_to include(microchip)
    expect(body).not_to have_key("microchip")
    expect(body["has_microchip"]).to be(true)
    expect(body.keys).to include("vaccinations", "observations", "tests", "collars", "stays", "neuterings", "euthanasia")
    expect(body["stays"].sole).to include("id" => stay.id, "entry_kind" => "collection")
    # A veterinária no mesmo formato da resposta da escrita (Task 8): { name, crmv }.
    veterinarian = { "name" => vet.professional.professional_name, "crmv" => "CRMV-PR #{vet.professional.registration_number}" }
    expect(body["neuterings"].sole).to include("veterinarian" => veterinarian, "shelter_stay_id" => stay.id)
    expect(body["euthanasia"]).to include("id" => euthanasia.id, "reason" => "untreatable_suffering", "veterinarian" => veterinarian)
    expect(response.body).not_to include("veterinarian_name")
    expect(response.body).not_to include("Sofrimento sem tratamento")
    expect([ body["vaccinations"], body["observations"], body["tests"], body["collars"] ]).to eq([ [], [], [], [] ])
  end

  # Decisão 32 / §16: a observação ligada aparece no histórico sem a notificação do 25.
  it "detalhe com observação ligada não traz disease_notification_id nem o id da notificação" do
    animal = animal!
    observation = bite_observation!(animal: animal)
    get "/zoonoses/animals/#{animal.id}"
    expect(response).to have_http_status(:ok)
    item = json_body["observations"].sole
    expect(item).to include("id" => observation.id, "state" => "open")
    expect(item).not_to have_key("disease_notification_id")
    expect(response.body).not_to include(observation.disease_notification_id)
  end

  it "PATCH: missing → active → ok; deceased → active → 409 animal_not_active; nome do transferred → 409 animal_not_active" do
    animal = animal!(status: "missing", status_on: Time.zone.today - 10)
    edit(animal, status: "active", expected_version: 1)
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("status" => "active", "status_on" => Time.zone.today.iso8601, "version" => 2)

    dead = animal!(status: "deceased")
    edit(dead, status: "active", expected_version: 1)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "animal_not_active" } ])
    moved = animal!(status: "transferred")
    edit(moved, name: "Rex", expected_version: 1)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "animal_not_active" } ])
  end

  it "PATCH: sem expected_version → 422 expected_version_required; velha → 409 animal_changed; transição fora → 409 invalid_transition" do
    animal = animal!
    edit(animal, name: "Rex")
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "expected_version_required", "path" => "expected_version" } ])
    edit(animal, name: "Rex", expected_version: 5)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "animal_changed" } ])
    edit(animal.tap { |a| a.update_columns(status: "missing") }, status: "transferred", expected_version: 1)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition", "path" => "status" } ])
    patch "/zoonoses/animals/#{SecureRandom.uuid}", params: { expected_version: 1 }.to_json, headers: headers
    expect(response).to have_http_status(:not_found)
  end
end
