require "rails_helper"

# Módulo 29 (ADR 0047; contrato §4, V14): catálogo, terminologias e calendário. Sem trilha.
RSpec.describe "Sala de vacina — catálogo", type: :request do
  let!(:city) { vaccination_city! }
  let(:room) { vaccine_room! }

  it "o vacinador da sala lê: versão do calendário, produtos e as seis terminologias { code, name }" do
    sign_in_as(room_member!(room))
    expect { get "/vaccination/catalog" }.not_to change(DomainEvent, :count)
    expect(response).to have_http_status(:ok)
    expect(json_body["calendar_version"]).to eq("2026.1")
    expect(json_body["terminologies"].keys).to eq(%w[dose strategy route site care_group maternal_condition])
    expect(json_body["terminologies"]["maternal_condition"]).to eq([ { "code" => "1", "name" => "Nenhuma" }, { "code" => "2", "name" => "Gestante" }, { "code" => "3", "name" => "Puérpera" } ])
    groups = json_body["terminologies"]["care_group"].map { |g| g["code"] }
    expect(groups).to include("121").and(satisfy { |codes| codes.size == 86 })
    expect(groups).not_to include("10") # OUTROS, inativo
    penta = json_body["immunobiologicals"].find { |p| p["code"] == "42" }
    expect(penta).to eq("code" => "42", "name" => "Vacina penta (DTP/HB/Hib)", "multidose" => false, "doses_per_vial" => 1,
                        "default_route" => "3", "default_site" => "18",
                        "manufacturers" => [ { "key" => "serum", "code" => nil, "name" => "Serum Institute of India", "validity_after_opening_hours" => 0 } ])
  end

  it "o almoxarife da rede de frio lê" do
    central = cold_chain_central!
    keeper = staff_with("frio@cidade.gov.br", "stock_keeper")
    StockLocationStaff.create!(stock_location: central, user: keeper, role: "stock_keeper", granted_by_user: pharmacy_admin!, granted_at: Time.current)
    sign_in_as(keeper)
    get "/vaccination/catalog"
    expect(response).to have_http_status(:ok)
  end

  it "usuário sem sala nem rede de frio → 403 missing_role; sem sessão → 401; interruptor desligado → 403 feature_disabled" do
    vaccine_room!
    sign_in_as(staff_with("ninguem-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional"))
    get "/vaccination/catalog"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

    sign_in_as(room_member!(room))
    get "/vaccination/catalog", params: { cpf: "1" }
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_request" ])

    Platform::Features.set!(city: city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
    get "/vaccination/catalog"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "vaccination" } ])
  end
end
