require "rails_helper"

# Módulo 35b, Task 8 (ADR 0054; contrato §7, §10, §16): /zoonoses/shelter_stays,
# para team? (403 missing_role). POST registra a entrada
# (Zoonoses::EnterShelter) → 201 com a estada e o animal (sem tutor); POST
# /:id/exit a saída (Zoonoses::ExitShelter); GET lista as estadas
# (open=1, health_unit_id) com a lotação por unidade, sem tutor nem adotante.
RSpec.describe "Zoonoses — canil e gatil", type: :request do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:headers) { { "CONTENT_TYPE" => "application/json" } }
  let(:today) { Time.zone.today }

  def json_post_to(path, fields) = post(path, params: fields.to_json, headers: headers)

  before { sign_in_as(team) }

  it "lotação por unidade; a lista não traz tutor" do
    kennel = uvz_unit!
    cattery = uvz_unit!
    tutor = tutor!
    tutored = animal!(tutor: tutor, name: "Rex")
    open_stays = [ shelter_stay!(animal: tutored, health_unit: kennel), shelter_stay!(animal: animal!, health_unit: kennel),
                   shelter_stay!(animal: animal!(species: "cat"), health_unit: cattery) ]
    closed = shelter_stay!(animal: animal!, health_unit: kennel, entered_on: today - 3)
    closed.update!(exit_kind: "transferred", exited_on: today - 1, version: 2)

    get "/zoonoses/shelter_stays?open=1"
    expect(response).to have_http_status(:ok)
    expect(json_body["items"].pluck("id")).to match_array(open_stays.map(&:id))
    expect(json_body["occupancy"]).to match_array([ { "health_unit_id" => kennel.id, "open_stays" => 2 },
                                                    { "health_unit_id" => cattery.id, "open_stays" => 1 } ])
    expect(json_body["items"].find { _1["animal_id"] == tutored.id }).to include("species" => "dog", "entry_kind" => "collection",
                                                                                 "health_unit_id" => kennel.id, "version" => 1)
    expect(response.body).not_to include(tutor.id)
    expect(response.body).not_to include(ZoonosesHelpers::ZOONOSES_TUTOR_NAME)

    get "/zoonoses/shelter_stays?health_unit_id=#{kennel.id}"
    expect(json_body["items"].pluck("id")).to match_array(open_stays.first(2).map(&:id) + [ closed.id ])
    expect(json_body["occupancy"]).to eq([ { "health_unit_id" => kennel.id, "open_stays" => 2 } ])

    get "/zoonoses/shelter_stays?open=yes"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "open" } ])
    get "/zoonoses/shelter_stays?tutor_patient_id=#{tutor.id}"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "entrada e saída pela rota; adotante nunca na resposta; fora da equipe → 403" do
    unit = uvz_unit!
    json_post_to("/zoonoses/shelter_stays", { health_unit_id: unit.id, entry_kind: "voluntary_surrender",
                                              new_animal: { species: "dog", sex: "male" } })
    expect(response).to have_http_status(:created)
    stay_id = json_body["id"]
    expect(json_body).to include("entry_kind" => "voluntary_surrender", "exited_on" => nil, "version" => 1)
    expect(json_body["animal"]).to include("species" => "dog", "has_tutor" => false, "household_id" => nil)

    json_post_to("/zoonoses/shelter_stays", { health_unit_id: unit.id, entry_kind: "collection", animal_id: json_body["animal_id"] })
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "stay_already_open" } ])

    linked = bite_observation!(animal: animal!)
    json_post_to("/zoonoses/shelter_stays", { health_unit_id: unit.id, entry_kind: "observation", animal_id: animal!.id,
                                              bite_observation_id: linked.id })
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "observation_changed" } ])

    adopter = tutor!
    json_post_to("/zoonoses/shelter_stays/#{stay_id}/exit", { exit_kind: "adopted", adopter_patient_id: adopter.id, expected_version: 2 })
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "stay_changed" } ])
    json_post_to("/zoonoses/shelter_stays/#{stay_id}/exit", { exit_kind: "adopted", adopter_patient_id: adopter.id, expected_version: 1 })
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => stay_id, "exit_kind" => "adopted", "exited_on" => today.iso8601, "version" => 2)
    expect(response.body).not_to include(adopter.id)

    json_post_to("/zoonoses/shelter_stays/#{SecureRandom.uuid}/exit", { exit_kind: "transferred", expected_version: 1 })
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])

    sign_in_as(staff_with("adm-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
    get "/zoonoses/shelter_stays"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end
end
