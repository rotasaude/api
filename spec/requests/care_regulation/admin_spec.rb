require "rails_helper"

# Módulo 26a (ADR 0044; contrato §6, G5): prazos por cor e lista do enfermeiro.
RSpec.describe "Regulação — prazos e lista do enfermeiro", type: :request do
  let!(:city) { regulation_city! }
  let(:admin) { regulation_admin! }
  let(:regulator) { care_regulator! }

  def deadlines = RegulationRiskDeadline.pluck(:color, :days).to_h

  describe "prazos" do
    it "GET devolve as quatro cores; o regulador lê" do
      sign_in_as(regulator)
      get "/regulation/admin/deadlines"
      expect([ response.status, json_body ]).to eq([ 200, { "red" => 7, "yellow" => 30, "green" => 90, "blue" => 180 } ])
    end

    it "PATCH com step-up altera os prazos (200, forma { red, yellow, green, blue })" do
      stepped_up!(admin)
      json_patch "/regulation/admin/deadlines", red: 3, yellow: 20, green: 60, blue: 120
      expect([ response.status, json_body ]).to eq([ 200, { "red" => 3, "yellow" => 20, "green" => 60, "blue" => 120 } ])
      expect(deadlines).to eq("red" => 3, "yellow" => 20, "green" => 60, "blue" => 120)
      get "/regulation/admin/deadlines"
      expect(json_body).to eq("red" => 3, "yellow" => 20, "green" => 60, "blue" => 120)
      expect(DomainEvent.where(name: "care_regulation.settings_changed").map(&:payload)).to eq([ { "user_id" => admin.id } ])
    end

    it "blue: 0 → 422 invalid_request com path blue; a tabela não muda" do
      stepped_up!(admin)
      json_patch "/regulation/admin/deadlines", red: 7, yellow: 30, green: 90, blue: 0
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "blue" } ])
      json_patch "/regulation/admin/deadlines", red: 7, yellow: 30, green: 90
      expect(json_body).to eq("error" => "invalid_request", "path" => "blue")
      json_patch "/regulation/admin/deadlines", red: "7", yellow: 30, green: 90, blue: 180
      expect(json_body).to eq("error" => "invalid_request", "path" => "red")
      expect(deadlines).to eq("red" => 7, "yellow" => 30, "green" => 90, "blue" => 180)
    end

    it "G5: yellow menor que red → 422 invalid_deadlines com path yellow; iguais valem" do
      stepped_up!(admin)
      json_patch "/regulation/admin/deadlines", red: 7, yellow: 5, green: 90, blue: 180
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_deadlines", "path" => "yellow" } ])
      expect(deadlines).to eq("red" => 7, "yellow" => 30, "green" => 90, "blue" => 180)
      json_patch "/regulation/admin/deadlines", red: 7, yellow: 7, green: 90, blue: 180
      expect(response).to have_http_status(:ok)
    end

    it "sem step-up → 401 mfa_required" do
      sign_in_as(step_up_enrolled!(admin))
      json_patch "/regulation/admin/deadlines", red: 3, yellow: 20, green: 60, blue: 120
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      expect(deadlines["red"]).to eq(7)
    end

    it "o regulador lê (200) e recebe 403 ao escrever, mesmo com step-up" do
      stepped_up!(regulator)
      get "/regulation/admin/deadlines"
      expect(response).to have_http_status(:ok)
      json_patch "/regulation/admin/deadlines", red: 3, yellow: 20, green: 60, blue: 120
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(deadlines["red"]).to eq(7)
    end

    it "profissional → 403 missing_role; sem sessão → 401; interruptor desligado → 403 feature_disabled" do
      get "/regulation/admin/deadlines"
      expect(response).to have_http_status(:unauthorized)
      sign_in_as(doctor!(create_unit("UBS Prazos")))
      get "/regulation/admin/deadlines"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

      Platform::Features.set!(city: city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(admin)
      get "/regulation/admin/deadlines"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "care_regulation" } ])
    end
  end

  describe "lista do enfermeiro" do
    it "POST (201) cria o item com o nome do alvo; GET lista; o regulador lê" do
      stepped_up!(admin)
      json_post "/regulation/admin/nurse_items", target_type: "specialty", target_code: "225250"
      expect(response).to have_http_status(:created)
      expect(json_body).to eq("target_type" => "specialty", "target_code" => "225250", "name" => "Ginecologia e obstetrícia")
      json_post "/regulation/admin/nurse_items", target_type: "procedure", target_code: "0209010037"
      expect(response).to have_http_status(:created)

      sign_in_as(regulator)
      get "/regulation/admin/nurse_items"
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("items" => [
        { "target_type" => "procedure", "target_code" => "0209010037", "name" => "ESOFAGOGASTRODUODENOSCOPIA" },
        { "target_type" => "specialty", "target_code" => "225250", "name" => "Ginecologia e obstetrícia" }
      ])
      expect(NurseRequestableItem.find_by(target_code: "225250").created_by_user).to eq(admin)
    end

    it "repetido → 409 duplicate_item" do
      stepped_up!(admin)
      json_post "/regulation/admin/nurse_items", target_type: "specialty", target_code: "225250"
      json_post "/regulation/admin/nurse_items", target_type: "specialty", target_code: "225250"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "duplicate_item" } ])
      expect(NurseRequestableItem.count).to eq(1)
    end

    it "alvo inválido → 422 invalid_target com path target_code" do
      stepped_up!(admin)
      [ %w[specialty 225125], %w[procedure 0305010107], %w[exam 225120] ].each do |type, code|
        json_post "/regulation/admin/nurse_items", target_type: type, target_code: code
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_target", "path" => "target_code" } ])
      end
      json_post "/regulation/admin/nurse_items", target_type: "specialty", target_code: 225_120
      expect(json_body).to eq("error" => "invalid_target", "path" => "target_code")
      json_post "/regulation/admin/nurse_items", {}
      expect(json_body).to eq("error" => "invalid_target", "path" => "target_code")
      expect(NurseRequestableItem.count).to eq(0)
    end

    it "exame ativo do catálogo → 422 invalid_target com hint exam_order" do
      exam_catalog_item!(sigtap_code: "0209010037")
      stepped_up!(admin)
      json_post "/regulation/admin/nurse_items", target_type: "procedure", target_code: "0209010037"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_target", "path" => "target_code", "hint" => "exam_order" } ])
    end

    it "DELETE (204) remove; item ausente → 404" do
      stepped_up!(admin)
      json_post "/regulation/admin/nurse_items", target_type: "specialty", target_code: "225250"
      json_delete "/regulation/admin/nurse_items", target_type: "specialty", target_code: "225250"
      expect(response).to have_http_status(:no_content)
      expect(NurseRequestableItem.count).to eq(0)
      json_delete "/regulation/admin/nurse_items", target_type: "specialty", target_code: "225250"
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    end

    it "sem step-up → 401 mfa_required; regulador escrevendo → 403; profissional → 403" do
      sign_in_as(step_up_enrolled!(admin))
      json_post "/regulation/admin/nurse_items", target_type: "specialty", target_code: "225250"
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])

      stepped_up!(regulator)
      json_post "/regulation/admin/nurse_items", target_type: "specialty", target_code: "225250"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      json_delete "/regulation/admin/nurse_items", target_type: "specialty", target_code: "225250"
      expect(response).to have_http_status(:forbidden)

      sign_in_as(doctor!(create_unit("UBS Lista")))
      get "/regulation/admin/nurse_items"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(NurseRequestableItem.count).to eq(0)
    end

    it "interruptor desligado → 403 feature_disabled" do
      Platform::Features.set!(city: city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(admin)
      get "/regulation/admin/nurse_items"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "care_regulation" } ])
    end
  end
end

# O banco de cidade carregado do dump nasce sem linhas em
# regulation_risk_deadlines (ruling da Task 2): o regulation_city! as insere,
# aqui a cidade fica como nasce.
RSpec.describe "Regulação — prazos numa cidade sem linhas", type: :request do
  before do
    regulation_sigtap!
    city = exam_city!
    Platform::Features.set!(city: city, key: "care_regulation", enabled: true, maintainer: ledi_maintainer!)
  end

  it "GET devolve os padrões (nunca erro); PATCH faz upsert das quatro cores" do
    expect(RegulationRiskDeadline.count).to eq(0)
    sign_in_as(regulation_admin!)
    get "/regulation/admin/deadlines"
    expect([ response.status, json_body ]).to eq([ 200, { "red" => 7, "yellow" => 30, "green" => 90, "blue" => 180 } ])

    stepped_up!(regulation_admin!)
    json_patch "/regulation/admin/deadlines", red: 1, yellow: 2, green: 3, blue: 4
    expect([ response.status, json_body ]).to eq([ 200, { "red" => 1, "yellow" => 2, "green" => 3, "blue" => 4 } ])
    expect(RegulationRiskDeadline.pluck(:color, :days).to_h).to eq("red" => 1, "yellow" => 2, "green" => 3, "blue" => 4)
  end
end
