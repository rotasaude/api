require "rails_helper"

# Contrato §3, K2, K12(d): doenças da cidade (plataforma vigente + locais).
RSpec.describe "Vigilância — doenças da cidade", type: :request do
  let!(:city) { surveillance_city! }

  let(:officer) { surveillance_officer! }
  let(:local_attrs) do
    { code: "local_picada_inseto_pr", name: "Picada de inseto (agravo local)", deadline: "weekly",
      cid10: %w[W57], ciap2: %w[S12], repeat_after_days: 15 }
  end

  def create_local!(over = {})
    stepped_up!(officer)
    json_post "/surveillance/admin/local_diseases", local_attrs.merge(over)
  end

  it "cria a doença local (201, forma <disease>) e ela aparece junto com a da plataforma" do
    create_local!
    expect(response).to have_http_status(:created)
    expect(json_body).to include("code" => "local_picada_inseto_pr", "name" => "Picada de inseto (agravo local)", "deadline" => "weekly",
                                 "cid10" => %w[W57], "ciap2" => %w[S12], "repeat_after_days" => 15, "sinan_form" => nil,
                                 "local" => true, "list_version" => nil, "notes" => nil, "active" => true)
    expect(json_body["id"]).to match(Surveillance::BaseController::UUID)
    expect(LocalNotifiableDisease.find(json_body["id"]).updated_by_user).to eq(officer)

    get "/surveillance/diseases"
    expect(response).to have_http_status(:ok)
    diseases = json_body["diseases"]
    expect(diseases.map { |d| d["code"] }).to include("dengue", "local_picada_inseto_pr")
    expect(diseases.map { |d| d["name"] }).to eq(diseases.map { |d| d["name"] }.sort_by { |n| I18n.transliterate(n).downcase })
    dengue = diseases.find { |d| d["code"] == "dengue" }
    expect(dengue).to include("local" => false, "list_version" => 1, "id" => nil, "active" => nil, "cid10" => %w[A90])
    expect(dengue.keys).to match_array(%w[code name deadline cid10 ciap2 repeat_after_days sinan_form local list_version notes id active])
  end

  it "K16: o analyst lê a lista (200); papel fora de vigilância, profissional e analyst → 403 missing_role" do
    sign_in_as(staff_with("analista-#{SecureRandom.hex(2)}@cidade.gov.br", "analyst"))
    get "/surveillance/diseases"
    expect(response).to have_http_status(:ok)
    expect(json_body["diseases"].map { |d| d["code"] }).to include("dengue")

    sign_in_as(staff_with("viewer-#{SecureRandom.hex(2)}@cidade.gov.br", "viewer"))
    get "/surveillance/diseases"
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "publica local_disease.changed só com ids" do
    create_local!
    event = DomainEvent.where(name: "local_disease.changed").last
    expect(event.payload).to eq("local_disease_id" => json_body["id"], "user_id" => officer.id)
  end

  it "sem step-up a escrita é 401 mfa_required (POST e PATCH)" do
    sign_in_as(step_up_enrolled!(officer))
    json_post "/surveillance/admin/local_diseases", local_attrs
    expect(response).to have_http_status(:unauthorized)
    expect(json_body).to eq("error" => "mfa_required")
    record = LocalNotifiableDisease.create!(local_attrs.merge(updated_by_user: officer))
    json_patch "/surveillance/admin/local_diseases/#{record.id}", name: "Outro nome"
    expect(response).to have_http_status(:unauthorized)
    expect(json_body).to eq("error" => "mfa_required")
    expect(LocalNotifiableDisease.count).to eq(1)
  end

  it "a leitura das locais não pede step-up e traz as inativas" do
    LocalNotifiableDisease.create!(local_attrs.merge(updated_by_user: officer, active: false))
    sign_in_as(officer)
    get "/surveillance/admin/local_diseases"
    expect(response).to have_http_status(:ok)
    expect(json_body["diseases"].map { |d| [ d["code"], d["active"] ] }).to eq([ [ "local_picada_inseto_pr", false ] ])
    get "/surveillance/diseases"
    expect(json_body["diseases"].map { |d| d["code"] }).not_to include("local_picada_inseto_pr")
  end

  it "422 invalid_disease com path: código sem prefixo, prazo, CID mal formado, repetição, texto longo (nunca truncado)" do
    create_local!(code: "picada_inseto")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_disease", "path" => "code")
    json_post "/surveillance/admin/local_diseases", local_attrs.merge(deadline: "monthly")
    expect(json_body).to eq("error" => "invalid_disease", "path" => "deadline")
    json_post "/surveillance/admin/local_diseases", local_attrs.merge(cid10: %w[W57 w58])
    expect(json_body).to eq("error" => "invalid_disease", "path" => "cid10.1")
    json_post "/surveillance/admin/local_diseases", local_attrs.merge(ciap2: "S12")
    expect(json_body).to eq("error" => "invalid_disease", "path" => "ciap2")
    json_post "/surveillance/admin/local_diseases", local_attrs.merge(repeat_after_days: 0)
    expect(json_body).to eq("error" => "invalid_disease", "path" => "repeat_after_days")
    json_post "/surveillance/admin/local_diseases", local_attrs.merge(name: "x" * 121)
    expect(json_body).to eq("error" => "invalid_disease", "path" => "name")
    json_post "/surveillance/admin/local_diseases", local_attrs.merge(active: "yes")
    expect(json_body).to eq("error" => "invalid_disease", "path" => "active")
    json_post "/surveillance/admin/local_diseases", local_attrs.except(:cid10)
    expect(json_body).to eq("error" => "invalid_disease", "path" => "cid10")
    expect(LocalNotifiableDisease.count).to eq(0)
  end

  it "409 duplicate_code: CID da plataforma (A90, e categoria que cobre A90x), CIAP da plataforma, mesmo código, CID/CIAP de outra local" do
    create_local!(cid10: %w[W57 A90])
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "duplicate_code", "path" => "cid10.1")
    json_post "/surveillance/admin/local_diseases", local_attrs.merge(cid10: %w[A920]) # A920 é da plataforma (4 caracteres exato)
    expect(json_body).to eq("error" => "duplicate_code", "path" => "cid10.0")
    json_post "/surveillance/admin/local_diseases", local_attrs.merge(cid10: %w[A15]) # categoria de 3 da plataforma
    expect(json_body).to eq("error" => "duplicate_code", "path" => "cid10.0")
    json_post "/surveillance/admin/local_diseases", local_attrs.merge(cid10: %w[A150]) # subcategoria de A15 da plataforma
    expect(json_body).to eq("error" => "duplicate_code", "path" => "cid10.0")
    json_post "/surveillance/admin/local_diseases", local_attrs.merge(ciap2: %w[A71])
    expect(json_body).to eq("error" => "duplicate_code", "path" => "ciap2.0")
    expect(LocalNotifiableDisease.count).to eq(0)

    json_post "/surveillance/admin/local_diseases", local_attrs
    expect(response).to have_http_status(:created)
    json_post "/surveillance/admin/local_diseases", local_attrs.merge(cid10: %w[W58])
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "duplicate_code", "path" => "code")
    other = local_attrs.merge(code: "local_outra_pr")
    json_post "/surveillance/admin/local_diseases", other.merge(cid10: %w[W57])
    expect(json_body).to eq("error" => "duplicate_code", "path" => "cid10.0")
    json_post "/surveillance/admin/local_diseases", other.merge(cid10: %w[W58], ciap2: %w[S12])
    expect(json_body).to eq("error" => "duplicate_code", "path" => "ciap2.0")
    json_post "/surveillance/admin/local_diseases", other.merge(cid10: %w[W58], ciap2: %w[S13])
    expect(response).to have_http_status(:created)
    expect(LocalNotifiableDisease.count).to eq(2)
  end

  it "PATCH edita, desativa e reativa; a doença sai da lista quando inativa" do
    create_local!
    id = json_body["id"]
    json_patch "/surveillance/admin/local_diseases/#{id}", name: "Picada de inseto", repeat_after_days: 7
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => id, "name" => "Picada de inseto", "repeat_after_days" => 7, "cid10" => %w[W57], "active" => true)
    json_patch "/surveillance/admin/local_diseases/#{id}", active: false
    expect(json_body).to include("active" => false)
    get "/surveillance/diseases"
    expect(json_body["diseases"].map { |d| d["code"] }).not_to include("local_picada_inseto_pr")
    json_patch "/surveillance/admin/local_diseases/#{id}", active: true
    expect(json_body).to include("active" => true)
    get "/surveillance/diseases"
    expect(json_body["diseases"].map { |d| d["code"] }).to include("local_picada_inseto_pr")
    expect(DomainEvent.where(name: "local_disease.changed").count).to eq(4)
  end

  it "PATCH: o código não muda, CID da plataforma recusa, id desconhecido é 404" do
    create_local!
    id = json_body["id"]
    json_patch "/surveillance/admin/local_diseases/#{id}", code: "local_outro_nome"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_disease", "path" => "code")
    json_patch "/surveillance/admin/local_diseases/#{id}", cid10: %w[W57 A90]
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "duplicate_code", "path" => "cid10.1")
    json_patch "/surveillance/admin/local_diseases/#{id}", code: "local_picada_inseto_pr", name: "Mesmo código é aceito"
    expect(response).to have_http_status(:ok)
    json_patch "/surveillance/admin/local_diseases/#{SecureRandom.uuid}", name: "x"
    expect(response).to have_http_status(:not_found)
    json_patch "/surveillance/admin/local_diseases/nao-e-uuid", name: "x"
    expect(response).to have_http_status(:not_found)
  end

  it "K12(d): versão nova da plataforma cobre o CID da local; a plataforma vence na lista e a local só é recusada na próxima edição" do
    create_local!
    id = json_body["id"]
    version = Surveillance::DiseaseList.current(today: Date.current)
    diseases = version.diseases.map { |d| d.attributes.slice("code", "name", "deadline", "cid10", "ciap2", "repeat_after_days", "sinan_form", "notes", "sources") }
    diseases.find { |d| d["code"] == "dengue" }["cid10"] = %w[A90 W57]
    result = Surveillance::DiseaseList::Publish.call(ordinance: "Portaria nova", effective_from: Date.current, expected_version: version.version, diseases: diseases)
    expect(result).to be_ok

    get "/surveillance/diseases"
    codes = json_body["diseases"].map { |d| d["code"] }
    expect(codes).to include("dengue", "local_picada_inseto_pr")
    diseases_now = Surveillance::Diseases.all
    expect(Surveillance::Matcher.disease_for("cid10", "W57", diseases_now).code).to eq("dengue")

    json_patch "/surveillance/admin/local_diseases/#{id}", name: "Editada depois"
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "duplicate_code", "path" => "cid10.0")
    json_patch "/surveillance/admin/local_diseases/#{id}", active: false # desativar sempre é possível
    expect(response).to have_http_status(:ok)
  end

  it "profissional de saúde lê diseases e recebe 403 missing_role em admin/local_diseases; sem papel nenhum, 403 também" do
    sign_in_as(staff_with("medico-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional"))
    get "/surveillance/diseases"
    expect(response).to have_http_status(:ok)
    expect(json_body["diseases"].map { |d| d["code"] }).to include("dengue")
    get "/surveillance/admin/local_diseases"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_role")
    json_post "/surveillance/admin/local_diseases", local_attrs
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_role")

    sign_in_as(staff_with("viewer-#{SecureRandom.hex(3)}@cidade.gov.br", "viewer"))
    get "/surveillance/diseases"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_role")
  end

  it "sem sessão é 401; escrita sem Content-Type JSON é 415" do
    get "/surveillance/diseases"
    expect(response).to have_http_status(:unauthorized)
    stepped_up!(officer)
    post "/surveillance/admin/local_diseases", params: local_attrs
    expect(response).to have_http_status(:unsupported_media_type)
  end

  it "interruptor desligado: 403 feature_disabled em tudo" do
    Platform::Features.set!(city: city, key: "surveillance", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    stepped_up!(officer)
    get "/surveillance/diseases"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "surveillance")
    json_post "/surveillance/admin/local_diseases", local_attrs
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "surveillance")
    get "/surveillance/admin/local_diseases"
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "surveillance")
  end
end
