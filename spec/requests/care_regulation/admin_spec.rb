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

# Módulo 26a (ADR 0044; contrato §6, G1/G5/G7): prestadores e ofertas com cota.
RSpec.describe "Regulação — prestadores e ofertas", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { regulation_city! }
  let(:admin) { regulation_admin! }
  let(:regulator) { care_regulator! }
  let(:unit) { HealthUnit.create!(name: "UBS Vila Hauer", kind: "ubs", cnes: "2384299") }

  def provider_events = DomainEvent.where(name: "care_provider.changed").map(&:payload)
  def offer_events = DomainEvent.where(name: "care_offer.changed").map(&:payload)

  # Duas autorizações vivas gravadas direto (a cota usada é só a contagem).
  def authorize_directly!(offer, count:, released: 0)
    (count + released).times do |i|
      request = regulation_request!(status: "pending")
      RegulationAuthorization.create!(
        regulation_request: request, care_offer: offer, authorized_by_user: admin, month: offer.month,
        released_at: (i < released ? Time.current : nil), release_reason: (i < released ? "cancelled" : nil)
      )
    end
  end

  describe "prestadores" do
    it "POST cria o prestador próprio da UBS (201) com o CNES da unidade" do
      stepped_up!(admin)
      json_post "/regulation/admin/providers", name: "UBS Vila Hauer", kind: "own", health_unit_id: unit.id
      expect(response).to have_http_status(:created)
      expect(json_body).to eq("id" => CareProvider.last.id, "name" => "UBS Vila Hauer", "cnes" => "2384299", "kind" => "own",
                              "health_unit" => { "id" => unit.id, "name" => "UBS Vila Hauer" }, "active" => true)
      expect(CareProvider.last.updated_by_user).to eq(admin)
      expect(provider_events).to eq([ { "care_provider_id" => CareProvider.last.id, "user_id" => admin.id } ])
    end

    it "o CNES do próprio é lido da unidade na hora: trocar o da unidade reflete no prestador sem salvá-lo de novo" do
      own = own_provider!(unit)
      stepped_up!(admin)
      get "/regulation/admin/providers"
      expect(json_body["providers"].sole).to include("id" => own.id, "cnes" => "2384299")
      expect(own.read_attribute(:cnes)).to be_nil

      unit.update!(cnes: "7654321")
      expect { get "/regulation/admin/providers" }.not_to(change { own.reload.updated_at })
      expect(json_body["providers"].sole).to include("cnes" => "7654321")
      expect(own.reload.cnes).to eq("7654321")

      unit.update!(cnes: nil)
      get "/regulation/admin/providers"
      expect(json_body["providers"].sole).to include("cnes" => nil)
    end

    it "unidade com o CNES de um externo (troca posterior): renomear e desativar o próprio continua 200, sem checar CNES" do
      own = own_provider!(unit)
      external_provider!(cnes: "3456781")
      unit.update!(cnes: "3456781")
      stepped_up!(admin)
      json_patch "/regulation/admin/providers/#{own.id}", active: false
      expect([ response.status, json_body["active"] ]).to eq([ 200, false ])
      json_patch "/regulation/admin/providers/#{own.id}", name: "UBS Vila Hauer Renomeada"
      expect([ response.status, json_body["name"] ]).to eq([ 200, "UBS Vila Hauer Renomeada" ])
    end

    it "o CNES novo da unidade vale para a trava de duplicidade: o externo não pode usá-lo" do
      own_provider!(unit)
      unit.update!(cnes: "7654321")
      stepped_up!(admin)
      json_post "/regulation/admin/providers", name: "Clínica J", kind: "contracted", cnes: "7654321"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "cnes_taken" } ])
      json_post "/regulation/admin/providers", name: "Clínica J", kind: "contracted", cnes: "2384299"
      expect(response).to have_http_status(:created)
    end

    it "POST cria o contratado com CNES (201), sem unidade" do
      stepped_up!(admin)
      json_post "/regulation/admin/providers", name: "Clínica de Olhos Araucária", kind: "contracted", cnes: "3456781"
      expect(response).to have_http_status(:created)
      expect(json_body).to include("cnes" => "3456781", "kind" => "contracted", "health_unit" => nil, "active" => true)
    end

    it "mesmo CNES → 409 cnes_taken; mesma unidade → 409 unit_taken" do
      stepped_up!(admin)
      json_post "/regulation/admin/providers", name: "Clínica A", kind: "contracted", cnes: "3456781"
      json_post "/regulation/admin/providers", name: "Clínica B", kind: "consortium", cnes: "3456781"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "cnes_taken" } ])
      json_post "/regulation/admin/providers", name: "UBS Vila Hauer", kind: "own", health_unit_id: unit.id
      json_post "/regulation/admin/providers", name: "UBS Vila Hauer 2", kind: "own", health_unit_id: unit.id
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "unit_taken" } ])
      # o CNES da unidade já é de outro prestador
      other = HealthUnit.create!(name: "UBS Outra", kind: "ubs", cnes: "3456781")
      json_post "/regulation/admin/providers", name: "UBS Outra", kind: "own", health_unit_id: other.id
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "cnes_taken" } ])
      expect(CareProvider.count).to eq(2)
      expect(provider_events.size).to eq(2)
    end

    it "own sem unidade, com unidade inativa ou inexistente → 422 invalid_request com path health_unit_id" do
      stepped_up!(admin)
      inactive = HealthUnit.create!(name: "UBS Fechada", kind: "ubs", cnes: "1234567", active: false)
      [ {}, { health_unit_id: inactive.id }, { health_unit_id: SecureRandom.uuid }, { health_unit_id: "x" } ].each do |extra|
        json_post "/regulation/admin/providers", { name: "UBS Qualquer", kind: "own" }.merge(extra)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "health_unit_id" } ])
      end
      expect(CareProvider.count).to eq(0)
    end

    it "own cuja unidade não tem CNES → 422 invalid_request com path health_unit_id" do
      stepped_up!(admin)
      no_cnes = HealthUnit.create!(name: "UBS Sem CNES", kind: "ubs")
      json_post "/regulation/admin/providers", name: "UBS Sem CNES", kind: "own", health_unit_id: no_cnes.id
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "health_unit_id" } ])
      expect(CareProvider.count).to eq(0)
    end

    it "own com CNES diferente do da unidade → 422 path cnes; igual vale; externo com unidade → 422 path health_unit_id" do
      stepped_up!(admin)
      json_post "/regulation/admin/providers", name: "UBS Vila Hauer", kind: "own", health_unit_id: unit.id, cnes: "9999999"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "cnes" } ])
      json_post "/regulation/admin/providers", name: "UBS Vila Hauer", kind: "own", health_unit_id: unit.id, cnes: "2384299"
      expect(response).to have_http_status(:created)
      json_post "/regulation/admin/providers", name: "Clínica C", kind: "ppi", cnes: "3456781", health_unit_id: unit.id
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "health_unit_id" } ])
    end

    it "externo sem CNES ou com CNES malformado → 422 path cnes; tipo inválido → path kind" do
      stepped_up!(admin)
      [ {}, { cnes: "123" }, { cnes: 3_456_781 } ].each do |extra|
        json_post "/regulation/admin/providers", { name: "Clínica D", kind: "contracted" }.merge(extra)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "cnes" } ])
      end
      json_post "/regulation/admin/providers", name: "Clínica D", kind: "hospital", cnes: "3456781"
      expect(json_body).to eq("error" => "invalid_request", "path" => "kind")
      json_post "/regulation/admin/providers", name: "Clínica D", kind: "contracted", cnes: "3456781", active: "yes"
      expect(json_body).to eq("error" => "invalid_request", "path" => "active")
    end

    it "G5: nome de 2 e de 121 caracteres → 422 path name; de 3 vale; nada é cortado" do
      stepped_up!(admin)
      [ "AB", "  A ", "a" * 121, nil, 7 ].each do |name|
        json_post "/regulation/admin/providers", name: name, kind: "contracted", cnes: "3456781"
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "name" } ])
      end
      json_post "/regulation/admin/providers", name: "ABC", kind: "contracted", cnes: "3456781"
      expect(response).to have_http_status(:created)
      json_post "/regulation/admin/providers", name: "b" * 120, kind: "contracted", cnes: "3456782"
      expect(response).to have_http_status(:created)
      expect(json_body["name"].length).to eq(120)
    end

    it "PATCH renomeia, desativa e troca o CNES do externo; o tipo e a unidade não mudam" do
      provider = external_provider!(cnes: "3456781", name: "Clínica E")
      stepped_up!(admin)
      json_patch "/regulation/admin/providers/#{provider.id}", name: "Clínica Eta", active: false, cnes: "3456782"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("name" => "Clínica Eta", "active" => false, "cnes" => "3456782")
      expect(provider_events).to eq([ { "care_provider_id" => provider.id, "user_id" => admin.id } ])

      json_patch "/regulation/admin/providers/#{provider.id}", kind: "own"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "kind" } ])
      json_patch "/regulation/admin/providers/#{provider.id}", health_unit_id: unit.id
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "health_unit_id" } ])
      json_patch "/regulation/admin/providers/#{provider.id}", name: "AB"
      expect(json_body).to eq("error" => "invalid_request", "path" => "name")
      # reenviar o mesmo tipo vale; sem mudança, sem evento
      json_patch "/regulation/admin/providers/#{provider.id}", kind: "contracted", name: "Clínica Eta"
      expect(response).to have_http_status(:ok)
      expect(provider_events.size).to eq(1)
    end

    it "PATCH do próprio: o CNES segue o da unidade; CNES diferente → 422 path cnes; CNES já usado → 409" do
      own = own_provider!(unit)
      other = external_provider!(cnes: "3456781")
      stepped_up!(admin)
      json_patch "/regulation/admin/providers/#{own.id}", cnes: "9999999"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "cnes" } ])
      json_patch "/regulation/admin/providers/#{own.id}", active: false
      expect(response).to have_http_status(:ok)
      json_patch "/regulation/admin/providers/#{other.id}", cnes: "2384299"
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "cnes_taken" } ])
      expect(other.reload.cnes).to eq("3456781")
    end

    it "PATCH de id inexistente ou malformado → 404" do
      stepped_up!(admin)
      json_patch "/regulation/admin/providers/#{SecureRandom.uuid}", name: "Clínica F"
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      json_patch "/regulation/admin/providers/nao-e-uuid", name: "Clínica F"
      expect(response).to have_http_status(:not_found)
    end

    it "o regulador lê a lista (por nome, no envelope providers) e recebe 403 ao escrever, mesmo com step-up" do
      own_provider!(unit)
      external_provider!(cnes: "3456781", name: "Clínica A")
      stepped_up!(regulator)
      get "/regulation/admin/providers"
      expect(response).to have_http_status(:ok)
      expect(json_body["providers"].map { |p| p["name"] }).to eq([ "Clínica A", "UBS Vila Hauer" ])
      expect(json_body["providers"].last).to include("kind" => "own", "health_unit" => { "id" => unit.id, "name" => "UBS Vila Hauer" })
      json_post "/regulation/admin/providers", name: "Clínica G", kind: "contracted", cnes: "3456782"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      json_patch "/regulation/admin/providers/#{CareProvider.first.id}", active: false
      expect(response).to have_http_status(:forbidden)
      expect(CareProvider.count).to eq(2)
    end

    it "sem step-up → 401 mfa_required; sem sessão → 401; profissional → 403; interruptor desligado → 403" do
      sign_in_as(step_up_enrolled!(admin))
      json_post "/regulation/admin/providers", name: "Clínica H", kind: "contracted", cnes: "3456781"
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      expect(CareProvider.count).to eq(0)

      sign_in_as(doctor!(create_unit("UBS Prestadores")))
      get "/regulation/admin/providers"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

      Platform::Features.set!(city: city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(admin)
      get "/regulation/admin/providers"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "care_regulation" } ])
    end

    it "escrita sem Content-Type JSON → 415" do
      stepped_up!(admin)
      post "/regulation/admin/providers", params: { name: "Clínica I", kind: "contracted", cnes: "3456781" }
      expect(response).to have_http_status(:unsupported_media_type)
    end
  end

  describe "ofertas" do
    let(:provider) { external_provider!(cnes: "3456781", name: "Clínica de Olhos") }

    around do |example|
      if example.metadata[:no_travel] then example.run
      else travel_to(Time.zone.local(2026, 10, 15, 10)) { example.run }
      end
    end

    def offer_body(**over)
      { provider_id: provider.id, target_type: "specialty", target_code: "225120", month: "2026-10", quantity: 5 }.merge(over)
    end

    it "POST cria a oferta do mês corrente (201) com used 0 e available 5" do
      stepped_up!(admin)
      json_post "/regulation/admin/offers", offer_body
      expect(response).to have_http_status(:created)
      expect(json_body).to eq("id" => CareOffer.last.id, "provider" => { "id" => provider.id, "name" => "Clínica de Olhos", "kind" => "contracted" },
                              "target" => { "type" => "specialty", "code" => "225120", "name" => "Cardiologia" },
                              "month" => "2026-10", "quantity" => 5, "used" => 0, "available" => 5)
      expect(CareOffer.last.month).to eq(Date.new(2026, 10, 1))
      expect(CareOffer.last.updated_by_user).to eq(admin)
      expect(offer_events).to eq([ { "care_offer_id" => CareOffer.last.id, "user_id" => admin.id } ])
    end

    it "mês futuro vale; mês passado → 422 invalid_month; formato ruim → 422 path month" do
      stepped_up!(admin)
      json_post "/regulation/admin/offers", offer_body(month: "2026-11")
      expect(response).to have_http_status(:created)
      json_post "/regulation/admin/offers", offer_body(month: "2026-09")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_month" } ])
      [ "2026-13", "2026-1", "out/2026", 202_610, nil ].each do |month|
        json_post "/regulation/admin/offers", offer_body(month: month)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "month" } ])
      end
      expect(CareOffer.count).to eq(1)
    end

    it "o mês corrente é o do fuso da cidade (31/10 23:30 em São Paulo já é 01/11 em UTC)", :no_travel do
      travel_to(Time.utc(2026, 11, 1, 2, 30)) do
        Time.use_zone("America/Sao_Paulo") do
          stepped_up!(admin)
          json_post "/regulation/admin/offers", offer_body(month: "2026-10")
          expect(response).to have_http_status(:created)
          json_post "/regulation/admin/offers", offer_body(month: "2026-09", target_code: "225250")
          expect(json_body).to eq("error" => "invalid_month")
        end
      end
    end

    it "repetida (prestador, alvo, mês) → 409 duplicate_offer; outro mês ou alvo vale" do
      stepped_up!(admin)
      json_post "/regulation/admin/offers", offer_body
      json_post "/regulation/admin/offers", offer_body(quantity: 9)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "duplicate_offer" } ])
      json_post "/regulation/admin/offers", offer_body(month: "2026-12")
      json_post "/regulation/admin/offers", offer_body(target_code: "225250")
      expect(CareOffer.count).to eq(3)
      expect(CareOffer.where(quantity: 9)).to be_empty
    end

    it "alvo inválido → 422 invalid_target; prestador ausente → 422 path provider_id; quantidade fora de 0..9999 → path quantity" do
      stepped_up!(admin)
      json_post "/regulation/admin/offers", offer_body(target_code: "225125")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_target", "path" => "target_code" } ])
      [ nil, "x", SecureRandom.uuid ].each do |id|
        json_post "/regulation/admin/offers", offer_body(provider_id: id)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "provider_id" } ])
      end
      [ -1, 10_000, "5", nil, 2.5 ].each do |quantity|
        json_post "/regulation/admin/offers", offer_body(quantity: quantity)
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "quantity" } ])
      end
      json_post "/regulation/admin/offers", offer_body(quantity: 0)
      expect(response).to have_http_status(:created)
      expect(json_body).to include("quantity" => 0, "available" => 0)
    end

    it "PATCH quantity abaixo do usado → 422 quantity_below_used; igual ao usado → 200 com available 0; liberada não conta" do
      offer = offer!(provider: provider, quantity: 5)
      authorize_directly!(offer, count: 2, released: 1)
      stepped_up!(admin)
      json_patch "/regulation/admin/offers/#{offer.id}", quantity: 1
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "quantity_below_used", "used" => 2 } ])
      expect(offer.reload.quantity).to eq(5)
      expect(offer_events).to be_empty

      json_patch "/regulation/admin/offers/#{offer.id}", quantity: 2
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("quantity" => 2, "used" => 2, "available" => 0)
      expect(offer_events).to eq([ { "care_offer_id" => offer.id, "user_id" => admin.id } ])
    end

    it "PATCH só muda a quantidade: prestador, alvo ou mês diferentes → 422 invalid_request; os mesmos valem" do
      offer = offer!(provider: provider, quantity: 5)
      stepped_up!(admin)
      { provider_id: external_provider!.id, target_type: "procedure", target_code: "225250", month: "2026-11" }.each do |key, value|
        json_patch "/regulation/admin/offers/#{offer.id}", quantity: 6, key => value
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => key.to_s } ])
      end
      expect(offer.reload.quantity).to eq(5)
      json_patch "/regulation/admin/offers/#{offer.id}", offer_body(quantity: 7)
      expect(response).to have_http_status(:ok)
      expect(offer.reload.quantity).to eq(7)
      json_patch "/regulation/admin/offers/#{offer.id}", quantity: 10_000
      expect(json_body).to eq("error" => "invalid_request", "path" => "quantity")
      json_patch "/regulation/admin/offers/#{offer.id}", {}
      expect(json_body).to eq("error" => "invalid_request", "path" => "quantity")
    end

    it "prestador inativo não recebe oferta nova (422 path provider_id); a quantidade de oferta já existente segue editável" do
      offer = offer!(provider: provider, quantity: 5)
      provider.update!(active: false)
      stepped_up!(admin)
      json_post "/regulation/admin/offers", offer_body(target_code: "225250")
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "provider_id" } ])
      expect(CareOffer.count).to eq(1)

      json_patch "/regulation/admin/offers/#{offer.id}", quantity: 8
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("quantity" => 8, "available" => 8)
    end

    it "PATCH sem mudança não publica evento; id inexistente → 404" do
      offer = offer!(provider: provider, quantity: 5)
      stepped_up!(admin)
      json_patch "/regulation/admin/offers/#{offer.id}", quantity: 5
      expect(response).to have_http_status(:ok)
      expect(offer_events).to be_empty
      json_patch "/regulation/admin/offers/#{SecureRandom.uuid}", quantity: 5
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    end

    it "o regulador lê a lista com used e available (mês corrente por padrão) e recebe 403 ao escrever" do
      cardio = offer!(provider: provider, quantity: 5)
      offer!(provider: provider, target_code: "225250", quantity: 3)
      offer!(provider: provider, quantity: 8, month: Date.new(2026, 11, 1))
      authorize_directly!(cardio, count: 2, released: 1)
      stepped_up!(regulator)

      get "/regulation/admin/offers"
      expect(response).to have_http_status(:ok)
      expect(json_body["offers"].map { |o| [ o["target"]["code"], o["month"], o["quantity"], o["used"], o["available"] ] })
        .to eq([ [ "225120", "2026-10", 5, 2, 3 ], [ "225250", "2026-10", 3, 0, 3 ] ])

      get "/regulation/admin/offers", params: { month: "2026-11" }
      expect(json_body["offers"].map { |o| [ o["month"], o["used"], o["available"] ] }).to eq([ [ "2026-11", 0, 8 ] ])
      get "/regulation/admin/offers", params: { target_code: "225250" }
      expect(json_body["offers"].map { |o| o["target"]["code"] }).to eq([ "225250" ])
      get "/regulation/admin/offers", params: { provider_id: external_provider!.id }
      expect(json_body["offers"]).to eq([])
      get "/regulation/admin/offers", params: { month: "2026-13" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "month" } ])
      get "/regulation/admin/offers", params: { provider_id: "x" }
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "provider_id" } ])

      json_post "/regulation/admin/offers", offer_body(month: "2026-12")
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      json_patch "/regulation/admin/offers/#{cardio.id}", quantity: 9
      expect(response).to have_http_status(:forbidden)
      expect(cardio.reload.quantity).to eq(5)
    end

    it "lista o nome do procedimento pela SIGTAP e não vaza texto de paciente" do
      offer!(provider: provider, target_type: "procedure", target_code: "0209010037", quantity: 4)
      sign_in_as(admin)
      get "/regulation/admin/offers"
      expect(json_body["offers"].first["target"]).to eq("type" => "procedure", "code" => "0209010037", "name" => "ESOFAGOGASTRODUODENOSCOPIA")
    end

    it "sem step-up → 401 mfa_required; profissional → 403; interruptor desligado → 403 feature_disabled" do
      sign_in_as(step_up_enrolled!(admin))
      json_post "/regulation/admin/offers", offer_body
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      expect(CareOffer.count).to eq(0)

      sign_in_as(doctor!(create_unit("UBS Ofertas")))
      get "/regulation/admin/offers"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

      Platform::Features.set!(city: city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(admin)
      get "/regulation/admin/offers"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "care_regulation" } ])
    end
  end
end
