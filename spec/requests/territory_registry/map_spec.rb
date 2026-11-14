require "rails_helper"

# Módulo 24c (ADR 0053; contrato §3.1, Q39): GET /territory/map entrega ao
# dashboard o mesmo arquivo de mapa do app, para quem lê ao menos uma microárea
# (ACS, enfermeiro, CBO de campo atribuído). Sem trilha.
RSpec.describe "Mapa de campo no dashboard — GET /territory/map", type: :request do
  let!(:city) { home_visit_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let!(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }

  before { published_field_map!(city) }

  it "ACS, enfermeiro e TACS atribuído leem o arquivo, com Range, sem trilha" do
    tacs = field_agent!(cbo: "322255", team: team)
    assignment!(area, tacs.professional)
    events = DomainEvent.where("name LIKE 'clinical_record.%'")
    [ acs, registry_nurse!(unit, team: team), tacs ].each do |user|
      sign_in_as(user)
      expect { get "/territory/map", headers: { "Range" => "bytes=0-6" } }.not_to change(events, :count)
      expect(response).to have_http_status(:partial_content)
      expect(response.body.b).to eq("PMTiles".b)
      expect(response.headers).to include("ETag" => %("#{field_map_sha}"), "Content-Type" => "application/vnd.pmtiles")
    end
    get "/territory/map"
    expect(response.body.bytesize).to eq(field_map_bytes.bytesize)
  end

  it "quem não lê nenhuma microárea → 403 missing_role; TACS sem atribuição também" do
    [ municipal_admin!, field_agent!(cbo: "322255", team: team) ].each do |user|
      sign_in_as(user)
      get "/territory/map"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
  end

  it "sem sessão → 401; sem mapa publicado → 404 map_not_found" do
    get "/territory/map"
    expect(response).to have_http_status(:unauthorized)
    FieldMap.where(city_id: city.id).delete_all
    sign_in_as(acs)
    get "/territory/map"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "map_not_found" } ])
  end
end
