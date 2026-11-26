# spec/requests/maintenance/obm_catalog_spec.rb
require "rails_helper"

# Módulo 27b, Q12: a carga OBM por arquivo, pelo maintenance, fora de produção
# (a API inteira não é desenhada em produção: config/routes.rb). Sessão humana,
# step-up de TOTP; o corpo maior vale só para esta operação.
RSpec.describe "Maintenance: carga OBM", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "obm-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let(:sample) { Rails.root.join("spec/fixtures/obm/sample.csv").read }
  let(:mutation) do
    "mutation($file: String!, $code: String!) { importObmCatalog(fileBase64: $file, code: $code) " \
      "{ ok errors { path message } added changed deactivated vmpLinked unmatched } }"
  end

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)
  def gql!(query, **variables) = post("/graphql", params: { query: query, variables: variables.to_json }, headers: browser)

  # O código do passo seguinte ao do login (um TOTP vale uma vez por conta).
  def with_fresh_totp
    @totp_clock = (@totp_clock || Time.current) + 31.seconds
    travel_to(@totp_clock) { yield(ROTP::TOTP.new(maintainer.otp_secret).now) }
  end

  def import!(csv = sample)
    with_fresh_totp { |code| gql!(mutation, file: Base64.strict_encode64(csv), code: code) }
  end

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    import_test_catalog!
    travel_to(1.minute.ago) do
      post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
      post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
                                 headers: browser
    end
  end

  it "sem TOTP → recusa e auditoria rejected" do
    gql!(mutation, file: Base64.strict_encode64(sample), code: "000000")

    expect(json.dig("data", "importObmCatalog")).to include("ok" => false, "errors" => [ { "path" => "code", "message" => "código inválido" } ])
    expect(ObmPresentation.count).to eq(0)
    expect(PlatformEvent.where(name: "maintenance.obm_catalog.imported").pluck(Arel.sql("payload->>'outcome'")))
      .to contain_exactly("attempted", "rejected")
  end

  it "com TOTP → ok, auditoria com rows e sem o conteúdo do arquivo" do
    import!

    expect(json.dig("data", "importObmCatalog"))
      .to eq("ok" => true, "errors" => [], "added" => 3, "changed" => 0, "deactivated" => 0, "vmpLinked" => 2, "unmatched" => 1)
    events = PlatformEvent.where(name: "maintenance.obm_catalog.imported").to_a
    expect(events.map { |e| e.payload["outcome"] }).to contain_exactly("attempted", "ok")
    expect(events.map(&:payload)).to all(include("rows" => 3, "module" => "medications"))
    expect(events.map { |e| e.payload.to_s }.join).not_to include("brasil", "LOSARTANA")
    expect(PlatformEvent.where(name: "obm_catalog.imported").last.payload)
      .to eq("actor" => "maintainer", "added" => 3, "changed" => 0, "deactivated" => 0, "unmatched" => 1)
  end

  it "arquivo inválido volta como erro no campo file, auditado rejected" do
    import!("AMPP;VMP\n@a;@b\n")

    expect(json.dig("data", "importObmCatalog")).to include("ok" => false)
    expect(json.dig("data", "importObmCatalog", "errors", 0)).to include("path" => "file", "message" => "invalid_file")
    # O tempo congela dentro do travel_to: a ordem do relógio não separa os dois.
    expect(PlatformEvent.where(name: "maintenance.obm_catalog.imported").map { |e| e.payload["outcome"] })
      .to contain_exactly("attempted", "rejected")
  end

  it "base64 inválido volta como invalid_file, sem rodar a importação" do
    expect(Medications::ObmImport).not_to receive(:call)
    with_fresh_totp { |code| gql!(mutation, file: "isto não é base64!", code: code) }

    expect(json.dig("data", "importObmCatalog", "errors", 0)).to include("path" => "file", "message" => "invalid_file")
  end

  it "obmUnmatched lista a apresentação sem item do catálogo" do
    import!
    gql!("{ medicationCatalog { obmUnmatched(first: 10) { amppCode vmpCode catmatCode description active manufacturerCnpj } " \
         "reviewItems(first: 1) { catmatCode } } }")

    expect(json.dig("data", "medicationCatalog", "obmUnmatched")).to eq(
      [ { "amppCode" => "@brasil20038375082", "vmpCode" => "@brasil10000003", "catmatCode" => 999_999,
          "description" => "MEDICAMENTO FORA DO CATALOGO 10 MG COM X 10", "active" => true, "manufacturerCnpj" => nil } ]
    )
  end

  it "o item do catálogo expõe vmpCode" do
    import!
    item = catalog_item(268_856)
    item.update_columns(parse_status: "review", hidden: true, review_reason: "manipulated")
    gql!("{ medicationCatalog { reviewItems(first: 5) { catmatCode vmpCode } } }")

    expect(json.dig("data", "medicationCatalog", "reviewItems")).to include("catmatCode" => 268_856, "vmpCode" => "@brasil10000001")
  end

  it "o SDL da carga OBM é o combinado com o maintenance" do
    sdl = Maintenance::Schema.to_definition
    expect(sdl).to match(/importObmCatalog\([^)]*\bcode: String![^)]*\bfileBase64: String![^)]*\): ImportObmCatalogPayload/m)
    expect(sdl).to include("type ImportObmCatalogPayload {\n  added: Int\n  changed: Int\n  deactivated: Int\n  errors: [UserError!]!\n  ok: Boolean!\n  unmatched: Int\n  vmpLinked: Int\n}")
    expect(sdl).to include("type ObmPresentation {\n  active: Boolean!\n  amppCode: String!\n  anvisaRegistration: String\n  catmatCode: Int\n  description: String!\n  importedAt: ISO8601DateTime!\n  manufacturerCnpj: String\n  vmpCode: String!\n}")
    expect(sdl).to match(/obmUnmatched\([^)]*first: Int = 50[^)]*\): \[ObmPresentation!\]!/m)
    expect(sdl).to include("type MedicationCatalogItem {\n  catmatCode: Int!\n  parseStatus: String!\n  sourceDescription: String!\n  vmpCode: String\n}")
  end

  describe "limite do corpo" do
    def json_post!(query, variables)
      post "/graphql", params: { query: query, variables: variables }.to_json,
                       headers: browser.merge("Content-Type" => "application/json")
    end

    it "corpo de 6 MB em importObmCatalog é lido; em outra operação → 413" do
      big = Base64.strict_encode64("x" * 4_400_000)
      expect(big.bytesize).to be > 5_800_000

      with_fresh_totp { |code| json_post!(mutation, { file: big, code: code }) }
      expect(response).to have_http_status(:ok)
      expect(json.dig("data", "importObmCatalog", "errors", 0)).to include("path" => "file", "message" => "invalid_file")

      json_post!("query($x: String) { me { id } }", { x: big })
      expect(response).to have_http_status(413)

      other = "mutation($file: String!, $code: String!) { importAnvisaLists { ok } importObmCatalog(fileBase64: $file, code: $code) { ok } }"
      json_post!(other, { file: big, code: "000000" })
      expect(response).to have_http_status(413)
    end

    it "acima do teto do upload → 413 mesmo em importObmCatalog" do
      huge = Base64.strict_encode64("x" * 5_300_000)
      json_post!(mutation, { file: huge, code: "000000" })
      expect(response).to have_http_status(413)
    end

    # Prova só o status: o parse do JSON pelo Rails pode já ter acontecido (e a
    # ParseError ser engolida pela instrumentação); o teto de memória do corpo é
    # o do proxy/Puma, não esta ação.
    it "acima do teto absoluto → 413 seja o corpo JSON válido ou não (o inválido não vira 400)" do
      body = "{" + ("x" * Maintenance::GraphqlController::UPLOAD_BODY_BYTES)
      post "/graphql", params: body, headers: browser.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(413)

      json_post!(mutation, { file: "A" * Maintenance::GraphqlController::UPLOAD_BODY_BYTES, code: "000000" })
      expect(response).to have_http_status(413)
    end

    it "o arquivo no texto da query (não em variables) segue no limite de 10 KB" do
      json_post!("mutation { importObmCatalog(fileBase64: \"#{'A' * 20_000}\", code: \"000000\") { ok } }", {})
      expect(response).to have_http_status(413)
    end
  end
end
