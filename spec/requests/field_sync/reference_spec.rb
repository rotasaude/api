require "rails_helper"

# Módulo 24c (ADR 0053; contrato §3.5): GET /field/v1/reference pela borda do
# app de campo (token do aparelho, sem query), sem trilha: não há dado de
# cidadão na referência.
RSpec.describe "App de campo — GET /field/v1/reference", type: :request do
  let!(:city) { home_visit_city!(collective: true) }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let!(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:token) { FieldDevices::Register.call(user: acs, name: "Celular").payload.fetch(:token) }

  def auth = { "Authorization" => "Bearer #{token}" }

  it "200 na forma do reference-response-v1, sem trilha" do
    events = DomainEvent.where("name LIKE 'clinical_record.%'")
    expect { get "/field/v1/reference", headers: auth }.not_to change(events, :count)
    expect(response).to have_http_status(:ok)
    expect(FieldSync::Schemas.errors("reference-response-v1", json_body)).to eq([])
    expect(json_body.fetch("team_professionals").map { _1["professional_id"] }).to include(acs.professional.id)
  end

  it "a sessão traz o mesmo reference_version da referência" do
    get "/field/v1/reference", headers: auth
    version = json_body.fetch("reference_version")
    get "/field/v1/session", headers: auth
    expect(json_body.fetch("reference_version")).to eq(version)
  end

  it "com query → 422 invalid_request; sem token → 401 invalid_token" do
    get "/field/v1/reference", params: { team_id: team.id }, headers: auth
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    get "/field/v1/reference"
    expect([ response.status, json_body ]).to eq([ 401, { "error" => "invalid_token" } ])
  end

  # Módulo 35a, Task 15 (Q8): o vector_control_domains da referência é o corpo
  # de GET /vector_control/domains (um serializador só).
  it "vector_control_domains só com o gate e igual ao GET /vector_control/domains (Q8)" do
    vector_product!(code: "PYR", charge_size: "1.00")
    get "/field/v1/reference", headers: auth
    expect(json_body).not_to have_key("vector_control_domains")
    Platform::Features.set!(city: city, key: VectorControl::Gate::KEY, enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!

    get "/field/v1/reference", headers: auth
    expect(response).to have_http_status(:ok)
    expect(FieldSync::Schemas.errors("reference-response-v1", json_body)).to eq([])
    reference = json_body.fetch("vector_control_domains")
    sign_in_as(endemic_coordinator!)
    get "/vector_control/domains"
    expect(response).to have_http_status(:ok)
    expect(reference).to eq(json_body)
  end
end
