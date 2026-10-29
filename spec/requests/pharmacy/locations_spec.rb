require "rails_helper"

# Módulo 27a (ADR 0045; contrato §3 e H2): meus locais, mínimos por local e
# busca de item do catálogo. É o primeiro request spec de cobertura do
# interruptor (403 feature_disabled) e do 422 com `problems`.
RSpec.describe "Farmácia — meus locais, mínimos e busca de item", type: :request do
  let!(:city) { pharmacy_city! }
  let(:unit) { create_unit("UBS Jardim das Flores") }
  let!(:central) { central_location! }
  let!(:farmacia) { unit_location!(unit) }
  let(:paracetamol) { catalog_item(267_778) }

  def json_put(path, params = {}) = put(path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" })
  def minimums_of(location) = StockMinimum.where(stock_location_id: location.id).pluck(:catalog_item_id, :minimum).to_h
  def events = DomainEvent.where(name: "pharmacy.settings_changed").order(:occurred_at, :id).map(&:payload)
  def disable_pharmacy! = Platform::Features.set!(city: city, key: "pharmacy", enabled: false, maintainer: ledi_maintainer!)

  describe "GET /pharmacy/locations (meus locais)" do
    it "a farmacêutica vê só a UBS dela, com roles [\"pharmacist\"] (os papéis fora da farmácia não entram)" do
      pharmacist = pharmacy_staff!(farmacia, "pharmacist")
      unit_location!
      expect(pharmacist.has_role?("health_professional")).to be(true)
      sign_in_as(pharmacist)
      get "/pharmacy/locations"
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("locations" => [ { "id" => farmacia.id, "name" => farmacia.name, "kind" => "unit",
                                                 "health_unit" => { "id" => unit.id, "name" => unit.name }, "active" => true,
                                                 "roles" => [ "pharmacist" ] } ])
    end

    it "o almoxarife do central vê todos os locais ativos; os alheios vêm com roles: []" do
      keeper = pharmacy_staff!(central, "stock_keeper")
      other = unit_location!
      inactive = unit_location!
      inactive.update!(active: false)
      sign_in_as(keeper)
      get "/pharmacy/locations"
      rows = json_body.fetch("locations")
      expect(rows.map { |row| row["id"] }).to match_array([ central.id, farmacia.id, other.id ])
      expect(rows.to_h { |row| [ row["id"], row["roles"] ] }).to eq(central.id => [ "stock_keeper" ], farmacia.id => [], other.id => [])
      expect(rows.find { |row| row["id"] == central.id }).to include("kind" => "central", "health_unit" => nil)
    end

    it "o papel no local aparece junto dos alheios: almoxarife do central que também está na UBS" do
      keeper = pharmacy_staff!(central, "stock_keeper")
      StockLocationStaff.create!(stock_location: farmacia, user: keeper, role: "stock_keeper", granted_by_user: pharmacy_admin!, granted_at: Time.current)
      Membership.create!(user: keeper, role: "pharmacist", granted_at: Time.current)
      StockLocationStaff.create!(stock_location: farmacia, user: keeper, role: "pharmacist", granted_by_user: pharmacy_admin!, granted_at: Time.current)
      sign_in_as(keeper)
      get "/pharmacy/locations"
      rows = json_body.fetch("locations").to_h { |row| [ row["id"], row["roles"] ] }
      expect(rows.fetch(farmacia.id)).to match_array(%w[stock_keeper pharmacist])
      expect(rows.fetch(central.id)).to eq([ "stock_keeper" ])
    end

    it "Review Focus 4: Membership revogada com o vínculo ainda ativo → lista vazia" do
      pharmacist = pharmacy_staff!(farmacia, "pharmacist")
      sign_in_as(pharmacist)
      get "/pharmacy/locations"
      expect(json_body.fetch("locations").size).to eq(1)

      pharmacist.memberships.active.find_by!(role: "pharmacist").revoke!
      expect(StockLocationStaff.active.where(user: pharmacist)).to exist
      get "/pharmacy/locations"
      expect([ response.status, json_body ]).to eq([ 200, { "locations" => [] } ])
    end

    it "vínculo revogado ou local desativado: some da lista; quem não tem papel nenhum recebe lista vazia" do
      assistant = pharmacy_staff!(farmacia, "pharmacy_assistant")
      sign_in_as(assistant)
      farmacia.update!(active: false)
      get "/pharmacy/locations"
      expect(json_body).to eq("locations" => [])

      sign_in_as(doctor!(unit))
      get "/pharmacy/locations"
      expect([ response.status, json_body ]).to eq([ 200, { "locations" => [] } ])
    end

    it "sem sessão → 401; interruptor desligado → 403 feature_disabled" do
      get "/pharmacy/locations"
      expect(response).to have_http_status(:unauthorized)

      keeper = pharmacy_staff!(central, "stock_keeper")
      disable_pharmacy!
      sign_in_as(keeper)
      get "/pharmacy/locations"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
    end
  end

  describe "mínimos por local" do
    let(:keeper) { pharmacy_staff!(farmacia, "stock_keeper") }

    it "GET sem mínimos devolve a lista vazia" do
      sign_in_as(keeper)
      get "/pharmacy/locations/#{farmacia.id}/minimums"
      expect([ response.status, json_body ]).to eq([ 200, { "minimums" => [] } ])
    end

    it "PUT grava (200, mesma forma do GET, com o item e a unidade de dispensação); sem step-up; o corpo `item` é ignorado" do
      sign_in_as(keeper)
      json_put "/pharmacy/locations/#{farmacia.id}/minimums",
               minimums: [ { catalog_item_id: losartana.id, minimum: "20", item: { name: "ignorado" } },
                           { catalog_item_id: paracetamol.id, minimum: "5.50" } ]
      expect(response).to have_http_status(:ok)
      rows = json_body.fetch("minimums")
      expect(rows.map { |row| row["catalog_item_id"] }).to match_array([ losartana.id, paracetamol.id ])
      expect(rows.find { |row| row["catalog_item_id"] == losartana.id }).to eq(
        "catalog_item_id" => losartana.id, "minimum" => "20.00",
        "item" => { "catalog_item_id" => losartana.id, "catmat_code" => 268_856, "name" => losartana.label, "unit" => "mg",
                    "dispensing_unit" => "unidade", "controlled" => false, "controlled_list" => nil }
      )
      expect(rows.find { |row| row["catalog_item_id"] == paracetamol.id }).to include("minimum" => "5.50")
      expect(rows.find { |row| row["catalog_item_id"] == paracetamol.id }.dig("item", "dispensing_unit")).to eq("comprimido")
      expect(minimums_of(farmacia)).to eq(losartana.id => 20, paracetamol.id => BigDecimal("5.5"))

      get "/pharmacy/locations/#{farmacia.id}/minimums"
      expect(json_body.fetch("minimums")).to match_array(rows)
      expect(events).to eq([ { "subject" => "minimums", "stock_location_id" => farmacia.id, "user_id" => keeper.id } ])
    end

    it "PUT substitui a lista: o que sai vira mínimo 0 (a linha fica, o alerta desliga) e o GET só mostra os maiores que zero" do
      sign_in_as(keeper)
      json_put "/pharmacy/locations/#{farmacia.id}/minimums",
               minimums: [ { catalog_item_id: losartana.id, minimum: "20" }, { catalog_item_id: paracetamol.id, minimum: "5" } ]
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", minimums: [ { catalog_item_id: paracetamol.id, minimum: "8" }, { catalog_item_id: amoxicilina.id, minimum: "0" } ]
      expect(response).to have_http_status(:ok)
      expect(json_body.fetch("minimums").map { |row| [ row["catalog_item_id"], row["minimum"] ] }).to eq([ [ paracetamol.id, "8.00" ] ])
      # "0" para um item que nunca teve mínimo não cria linha; o que já tinha fica em 0.
      expect(minimums_of(farmacia)).to eq(losartana.id => 0, paracetamol.id => 8)

      json_put "/pharmacy/locations/#{farmacia.id}/minimums", minimums: []
      expect(json_body).to eq("minimums" => [])
      expect(minimums_of(farmacia).values).to all(be_zero)
    end

    it "mesma lista de novo: 200 e nenhum evento novo; os outros locais não são tocados" do
      other = unit_location!
      StockMinimum.create!(stock_location: other, catalog_item_id: losartana.id, minimum: 9, updated_by_user: keeper)
      sign_in_as(keeper)
      body = { minimums: [ { catalog_item_id: losartana.id, minimum: "20" } ] }
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", body
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", body
      expect(response).to have_http_status(:ok)
      expect(events.size).to eq(1)
      expect(minimums_of(other)).to eq(losartana.id => 9)
    end

    it "o almoxarife do central lê e grava os mínimos de qualquer local" do
      central_keeper = pharmacy_staff!(central, "stock_keeper")
      sign_in_as(central_keeper)
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", minimums: [ { catalog_item_id: losartana.id, minimum: "12" } ]
      expect(response).to have_http_status(:ok)
      get "/pharmacy/locations/#{farmacia.id}/minimums"
      expect(json_body.fetch("minimums").map { |row| row["minimum"] }).to eq([ "12.00" ])
    end

    it "PUT de outro local → 403 missing_role; o farmacêutico e o auxiliar do próprio local também (só o almoxarife)" do
      other = unit_location!
      sign_in_as(keeper)
      json_put "/pharmacy/locations/#{other.id}/minimums", minimums: [ { catalog_item_id: losartana.id, minimum: "12" } ]
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      get "/pharmacy/locations/#{other.id}/minimums"
      expect(response).to have_http_status(:forbidden)
      expect(minimums_of(other)).to be_empty

      sign_in_as(pharmacy_staff!(farmacia, "pharmacist"))
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", minimums: []
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(pharmacy_staff!(farmacia, "pharmacy_assistant"))
      get "/pharmacy/locations/#{farmacia.id}/minimums"
      expect(response).to have_http_status(:forbidden)
    end

    it "Membership stock_keeper revogada derruba o acesso mesmo com o vínculo ativo" do
      keeper.memberships.active.find_by!(role: "stock_keeper").revoke!
      sign_in_as(keeper)
      get "/pharmacy/locations/#{farmacia.id}/minimums"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end

    it "local inexistente ou id mal formado → 404; local desativado: GET lê, PUT → 409 location_inactive" do
      sign_in_as(keeper)
      get "/pharmacy/locations/#{SecureRandom.uuid}/minimums"
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      json_put "/pharmacy/locations/nao-e-uuid/minimums", minimums: []
      expect(response).to have_http_status(:not_found)

      farmacia.update!(active: false)
      get "/pharmacy/locations/#{farmacia.id}/minimums"
      expect(response).to have_http_status(:ok)
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", minimums: []
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "location_inactive" } ])
    end

    it "item repetido → 422 invalid_request com o path da segunda ocorrência; nada é gravado" do
      sign_in_as(keeper)
      json_put "/pharmacy/locations/#{farmacia.id}/minimums",
               minimums: [ { catalog_item_id: losartana.id, minimum: "20" }, { catalog_item_id: paracetamol.id, minimum: "5" },
                           { catalog_item_id: losartana.id, minimum: "30" } ]
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_request", "path" => "minimums[2].catalog_item_id",
                              "problems" => [ { "path" => "minimums[2].catalog_item_id", "error" => "invalid_request" } ])
      expect(minimums_of(farmacia)).to be_empty
      expect(events).to be_empty
    end

    it "render_failure com problems: dois itens inválidos → o 1º no topo e os dois em problems; nada é gravado" do
      StockMinimum.create!(stock_location: farmacia, catalog_item_id: amoxicilina.id, minimum: 3, updated_by_user: keeper)
      sign_in_as(keeper)
      json_put "/pharmacy/locations/#{farmacia.id}/minimums",
               minimums: [ { catalog_item_id: losartana.id, minimum: "1,5" }, { catalog_item_id: SecureRandom.uuid, minimum: "5" },
                           { catalog_item_id: paracetamol.id, minimum: "5" } ]
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_quantity", "path" => "minimums[0].minimum",
                              "problems" => [ { "path" => "minimums[0].minimum", "error" => "invalid_quantity" },
                                              { "path" => "minimums[1].catalog_item_id", "error" => "invalid_item" } ])
      expect(minimums_of(farmacia)).to eq(amoxicilina.id => 3)
    end

    it "quantidade como no papel: vírgula, número JSON, 3 casas, sinal e acima do teto são recusados, nunca arredondados; zero vale" do
      sign_in_as(keeper)
      [ "1,5", 1.5, 2, "0.001", "-2", "100000", " 3", nil ].each do |bad|
        json_put "/pharmacy/locations/#{farmacia.id}/minimums", minimums: [ { catalog_item_id: losartana.id, minimum: bad } ]
        expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_quantity", "minimums[0].minimum" ]), "esperava recusa para #{bad.inspect}"
      end
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", minimums: [ { catalog_item_id: losartana.id, minimum: "0" } ]
      expect(response).to have_http_status(:ok)
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", minimums: [ { catalog_item_id: losartana.id, minimum: "99999.99" } ]
      expect(json_body.fetch("minimums").first["minimum"]).to eq("99999.99")
    end

    it "item fora do catálogo ou removido → 422 invalid_item; linha que não é objeto → 422 invalid_request" do
      sign_in_as(keeper)
      removed = catalog_item(267_778)
      removed.update!(status: "removed")
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", minimums: [ { catalog_item_id: removed.id, minimum: "1" } ]
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_item", "minimums[0].catalog_item_id" ])
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", minimums: [ { catalog_item_id: nil, minimum: "1" }, "x" ]
      expect(json_body["problems"]).to eq([ { "path" => "minimums[0].catalog_item_id", "error" => "invalid_item" },
                                            { "path" => "minimums[1]", "error" => "invalid_request" } ])
    end

    it "corpo sem a lista `minimums` (ou com outro tipo) → 422 invalid_request path minimums; query não vale como corpo" do
      sign_in_as(keeper)
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", {}
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "minimums" } ])
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", minimums: { catalog_item_id: losartana.id }
      expect(json_body).to eq("error" => "invalid_request", "path" => "minimums")
      put "/pharmacy/locations/#{farmacia.id}/minimums?minimums[][catalog_item_id]=#{losartana.id}&minimums[][minimum]=1",
          params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
      expect(json_body).to eq("error" => "invalid_request", "path" => "minimums")
      expect(minimums_of(farmacia)).to be_empty
    end

    it "escrita sem Content-Type JSON é recusada (415); sem sessão → 401; interruptor desligado → 403 feature_disabled" do
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", minimums: []
      expect(response).to have_http_status(:unauthorized)

      sign_in_as(keeper)
      put "/pharmacy/locations/#{farmacia.id}/minimums", params: { minimums: [] }.to_json, headers: { "CONTENT_TYPE" => "text/plain" }
      expect(response).to have_http_status(:unsupported_media_type)

      disable_pharmacy!
      get "/pharmacy/locations/#{farmacia.id}/minimums"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
      json_put "/pharmacy/locations/#{farmacia.id}/minimums", minimums: []
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /pharmacy/items/search" do
    let(:pharmacist) { pharmacy_staff!(farmacia, "pharmacist") }

    it "{ q: \"losart\" } traz a LOSARTANA com catalog_item_id, a concentração em unit, a unidade de dispensação e nenhuma chave de paciente" do
      sign_in_as(pharmacist)
      json_post "/pharmacy/items/search", q: "losart"
      expect(response).to have_http_status(:ok)
      items = json_body.fetch("items")
      row = items.find { |item| item["catalog_item_id"] == losartana.id }
      expect(row).to eq("catalog_item_id" => losartana.id, "catmat_code" => 268_856, "name" => losartana.label, "unit" => "mg",
                        "dispensing_unit" => "unidade", "controlled" => false, "controlled_list" => nil)
      expect(items.map(&:keys).uniq).to eq([ row.keys ])
      expect(response.body).not_to match(/patient|cpf|cns|paciente/i)
    end

    it "a forma do catálogo vira a unidade de dispensação (PARACETAMOL → comprimido); controlado sai marcado" do
      sign_in_as(pharmacist)
      json_post "/pharmacy/items/search", q: "paracetamol"
      expect(json_body.fetch("items").find { |item| item["catalog_item_id"] == paracetamol.id }).to include("dispensing_unit" => "comprimido", "unit" => paracetamol.unit)
      diazepam
      json_post "/pharmacy/items/search", q: "diazepam"
      expect(json_body.fetch("items").first).to include("controlled" => true, "controlled_list" => "B1")
    end

    it "q curta ou sem resultado → lista vazia; o almoxarife, o auxiliar e o admin também buscam" do
      json_post "/pharmacy/items/search", q: "l"
      sign_in_as(pharmacist)
      json_post "/pharmacy/items/search", q: "l"
      expect([ response.status, json_body ]).to eq([ 200, { "items" => [] } ])
      json_post "/pharmacy/items/search", q: "zzzzzz"
      expect(json_body).to eq("items" => [])

      [ pharmacy_staff!(farmacia, "stock_keeper"), pharmacy_staff!(farmacia, "pharmacy_assistant"), pharmacy_admin! ].each do |user|
        sign_in_as(user)
        json_post "/pharmacy/items/search", q: "losart"
        expect(response).to have_http_status(:ok)
        expect(json_body.fetch("items").map { |item| item["catalog_item_id"] }).to include(losartana.id)
      end
    end

    it "quem não tem papel na farmácia → 403 missing_role (profissional; farmacêutico com a Membership revogada)" do
      sign_in_as(doctor!(unit))
      json_post "/pharmacy/items/search", q: "losart"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

      pharmacist.memberships.active.find_by!(role: "pharmacist").revoke!
      sign_in_as(pharmacist)
      json_post "/pharmacy/items/search", q: "losart"
      expect(response).to have_http_status(:forbidden)
    end

    it "q ausente, que não é texto ou só na query → 422 invalid_request path q" do
      sign_in_as(pharmacist)
      [ {}, { q: 5 }, { q: [ "losart" ] } ].each do |body|
        json_post "/pharmacy/items/search", body
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "q" } ])
      end
      post "/pharmacy/items/search?q=losart", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
      expect(json_body).to eq("error" => "invalid_request", "path" => "q")
    end

    it "catálogo indisponível → 503 catalog_unavailable" do
      sign_in_as(pharmacist)
      allow(Medications::Search).to receive(:available?).and_return(false)
      json_post "/pharmacy/items/search", q: "losart"
      expect([ response.status, json_body ]).to eq([ 503, { "error" => "catalog_unavailable" } ])
    end

    it "sem sessão → 401; interruptor desligado → 403 feature_disabled" do
      json_post "/pharmacy/items/search", q: "losart"
      expect(response).to have_http_status(:unauthorized)

      sign_in_as(pharmacist)
      disable_pharmacy!
      json_post "/pharmacy/items/search", q: "losart"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "pharmacy" } ])
    end
  end
end
