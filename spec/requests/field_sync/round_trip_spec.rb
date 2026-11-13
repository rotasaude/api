require "rails_helper"

# Módulo 24b (ADR 0052; contrato §9.3; Q27, Q64; revisão final B-M6): a ida e
# volta do app de campo pela borda real. O envio (domicílio novo, paciente e o
# cadastro que os cita por household_client_uuid e patient_client_uuid) volta
# no download seguinte, com o cursor guardado, com os mesmos ids e versões; o
# envio que tira o cadastro do escopo (sem domicílio, fora de área) volta como
# lápide `moved` em `removals`. O relógio anda à mão (o corte de agora − 2 s do
# download) e todo laço de paginação tem teto fixo (max_pages).
RSpec.describe "App de campo — ida e volta (envio → download)", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  def max_pages = 12

  let!(:city) { home_visit_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let!(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:token) { FieldDevices::Register.call(user: acs, name: "Celular").payload.fetch(:token) }
  let(:start) { Time.current.change(usec: 0) }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def headers = { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
  def item(type, body, uuid: SecureRandom.uuid) = { "client_uuid" => uuid, "type" => type, "body" => body }

  def send_upload(*items, at:)
    travel_to(at) { post "/field/v1/uploads", params: { items: items }.to_json, headers: headers }
    expect(response).to have_http_status(:ok)
    expect(FieldSync::Schemas.errors("upload-response-v1", json_body)).to eq([])
    json_body.fetch("results")
  end

  # Todas as páginas a partir de `cursor`. -> [items, removals, cursor guardado]
  def download(cursor, at:)
    items = []
    removals = []
    travel_to(at) do
      max_pages.times do
        get "/field/v1/changes", params: { cursor: cursor, limit: 2 }.compact, headers: headers.except("Content-Type")
        expect(response).to have_http_status(:ok)
        expect(FieldSync::Schemas.errors("changes-response-v1", json_body)).to eq([])
        items.concat(json_body.fetch("items"))
        removals.concat(json_body.fetch("removals"))
        cursor = json_body.fetch("next_cursor")
        break unless json_body.fetch("has_more")
      end
    end
    expect(json_body.fetch("has_more")).to be(false)
    expect(cursor).to be_present
    [ items, removals, cursor ]
  end

  def registry_items(items) = items.select { |row| %w[household registration].include?(row["type"]) }.map { |row| [ row["type"], row["id"], row["version"] ] }

  it "o envio volta no download com o cursor guardado (mesmos ids e versões); tirar o cadastro do escopo vira lápide" do
    _, _, cursor = download(nil, at: start + 3.seconds)

    patient_uuid = SecureRandom.uuid
    household_uuid = SecureRandom.uuid
    household = { "micro_area_id" => area.id, "property_type" => "1", "refused" => false, "contact_phone" => "4133334444",
                  "address" => registry_address, "living_conditions" => registry_living_conditions }
    registration = registry_registration_sections.deep_stringify_keys.merge(
      "is_responsible" => false, "household_client_uuid" => household_uuid, "patient_client_uuid" => patient_uuid,
      "patient_demographics" => { "race_color" => "01", "ethnicity" => nil }
    )
    registration["identification"] = registration["identification"].merge("desconhece_nome_mae" => true)
    typed = { "full_name" => "Benedita Alves Rocha", "birth_date" => "1951-03-08", "sex" => "female", "no_cpf_reason" => "3" }
    results = send_upload(item("patient", { "new_patient" => typed }, uuid: patient_uuid), item("household", household, uuid: household_uuid),
                          item("individual_registration", registration), at: start + 10.seconds)
    expect(results.map { _1["status"] }).to eq(%w[accepted accepted accepted])
    saved_household = Household.find(results[1]["id"])
    saved = IndividualRegistration.find(results[2]["id"])
    expect(saved).to have_attributes(household_id: saved_household.id, patient_id: results[0]["id"], micro_area_id: area.id)

    items, removals, cursor = download(cursor, at: start + 15.seconds)
    expect(registry_items(items)).to contain_exactly([ "household", saved_household.id, saved_household.reload.version ],
                                                     [ "registration", saved.id, saved.reload.version ])
    expect(items.find { _1["type"] == "registration" }.dig("body", "household_id")).to eq(saved_household.id)
    expect(removals).to eq([])

    patient = Patient.find(results[0]["id"])
    moved = registry_registration_params(team, patient: patient).merge("registration_id" => saved.id, "version" => saved.version)
    expect(send_upload(item("individual_registration", moved), at: start + 20.seconds).sole).to include("status" => "accepted", "id" => saved.id)
    expect(saved.reload).to have_attributes(household_id: nil, micro_area_id: nil)

    items, removals, = download(cursor, at: start + 25.seconds)
    expect(removals).to eq([ { "type" => "registration", "id" => saved.id, "reason" => "moved" } ])
    expect(registry_items(items).map(&:second)).not_to include(saved.id)
  end
end
