# spec/requests/maintenance/medication_catalog_spec.rb
require "rails_helper"

# Contrato §8: o maintenance lê a release ativa e a lista de revisão e aciona
# as duas importações. Sessão humana só; nenhuma cidade é aberta.
RSpec.describe "Maintenance: catálogo de medicamentos", type: :request do
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "med-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)
  def gql!(query) = post("/graphql", params: { query: query, variables: "{}" }, headers: browser)

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    stub_const("Medications::AnvisaImport::DIR", anvisa_fixture_dir)
    allow(Medications::Catmat::Client).to receive(:new).and_wrap_original { |m, **kw| m.call(**kw, sleeper: ->(_) {}) }
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
         headers: browser
  end

  it "importa as listas, depois o catálogo; lê a release e a revisão; audita tentativa e resultado" do
    expect(Maintenance::CityReader).not_to receive(:call)
    gql!("mutation { importAnvisaLists { ok errors { path message } antimicrobials controlled } }")
    expect(json.dig("data", "importAnvisaLists")).to eq("ok" => true, "errors" => [], "antimicrobials" => 7, "controlled" => 6)

    stub_catmat!
    gql!("mutation { importMedicationCatalog { ok errors { message } releaseId added changed removed } }")
    payload = json.dig("data", "importMedicationCatalog")
    expect(payload).to include("ok" => true, "added" => 17, "changed" => 0, "removed" => 0)

    gql!("{ medicationCatalog { currentRelease { id importedAt itemsCount hiddenCount } reviewItems(first: 10) { catmatCode sourceDescription parseStatus } } }")
    catalog = json.dig("data", "medicationCatalog")
    expect(catalog["currentRelease"]).to include("id" => payload["releaseId"], "itemsCount" => 17, "hiddenCount" => 1)
    expect(catalog["reviewItems"]).to eq([ { "catmatCode" => 384_258, "parseStatus" => "review",
                                             "sourceDescription" => catalog_item(384_258).source_description } ])
    names = PlatformEvent.where("name LIKE 'maintenance.%imported'").pluck(:name, Arel.sql("payload->>'outcome'"))
    expect(names).to include([ "maintenance.anvisa_lists.imported", "ok" ], [ "maintenance.medication_catalog.imported", "ok" ])
  end

  it "fonte fora do ar: ok false com o motivo, nada ativo muda" do
    stub_catmat!(catmat_rows, pages: { 1 => { status: 503 } })
    gql!("mutation { importMedicationCatalog { ok errors { path message } releaseId } }")
    expect(json.dig("data", "importMedicationCatalog"))
      .to eq("ok" => false, "errors" => [ { "path" => "catalog", "message" => "source_unavailable" } ], "releaseId" => nil)
    expect(MedicationCatalogRelease.current).to be_nil
  end

  it "token de serviço, de qualquer nível, não alcança os três campos: recusa antes de executar" do
    _record, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read_write",
                                              city_slugs: [], expires_at: 10.days.from_now)
    bearer = { "Authorization" => "Bearer #{secret}", "Cookie" => "" }
    expect(Medications::CatalogImport).not_to receive(:call)
    expect(Medications::AnvisaImport).not_to receive(:call)

    [ "mutation { importMedicationCatalog { ok } }", "mutation { importAnvisaLists { ok } }",
      "{ medicationCatalog { currentRelease { id } } }" ].each do |query|
      post "/graphql", params: { query: query, variables: "{}" }, headers: bearer
      expect(json["errors"]).to be_present
      expect(json["data"]).to be_nil
    end
    expect(PlatformEvent.where(name: %w[maintenance.medication_catalog.imported maintenance.anvisa_lists.imported])).to be_empty
  end
  # Prova no navegador: o CATMAT real leva ~25 s; com o limite de 10 s do
  # schema a importação concluía e a resposta voltava "Timeout on
  # ImportMedicationCatalog.ok". O relógio monotônico (o mesmo que
  # GraphQL::Schema::Timeout lê) salta dentro da chamada lenta.
  describe "limite de tempo do GraphQL" do
    let(:clock_offset_ms) { [ 0 ] }

    before do
      allow(Process).to receive(:clock_gettime).and_wrap_original do |original, *args|
        value = original.call(*args)
        args == [ Process::CLOCK_MONOTONIC, :millisecond ] ? value + clock_offset_ms[0] : value
      end
    end

    def slow!(klass, method, seconds:)
      allow(klass).to receive(method).and_wrap_original do |original, *args, **kw|
        original.call(*args, **kw).tap { clock_offset_ms[0] += seconds * 1000 }
      end
    end

    it "importMedicationCatalog que passa de 10 s (até 300 s) responde ok, sem Timeout" do
      stub_catmat!
      slow!(Medications::CatalogImport, :call, seconds: 25)
      gql!("mutation { importMedicationCatalog { ok errors { message } added } }")
      expect(json["errors"]).to be_nil
      expect(json.dig("data", "importMedicationCatalog")).to include("ok" => true, "errors" => [], "added" => 17)
    end

    it "importAnvisaLists que passa de 10 s responde ok, sem Timeout" do
      slow!(Medications::AnvisaImport, :call, seconds: 25)
      gql!("mutation { importAnvisaLists { ok errors { message } } }")
      expect(json["errors"]).to be_nil
      expect(json.dig("data", "importAnvisaLists")).to include("ok" => true)
    end

    it "query comum continua com 10 s: passou disso, o campo seguinte cai no Timeout" do
      slow!(MedicationCatalogRelease, :current, seconds: 11)
      gql!("{ medicationCatalog { currentRelease { id } reviewItems(first: 1) { catmatCode } } }")
      expect(json["errors"].map { |e| e["message"] }).to include(a_string_starting_with("Timeout on"))
    end
  end

  describe "Maintenance::Timeout" do
    subject(:timeout) { Maintenance::Timeout.new(max_seconds: 10) }

    def limit_for(query_string) = timeout.max_seconds(GraphQL::Query.new(Maintenance::Schema, query_string))

    it "300 s só para operação feita apenas das importações; o resto fica com os 10 s do schema" do
      expect(limit_for("mutation { importMedicationCatalog { ok } }")).to eq(300)
      expect(limit_for("mutation { importAnvisaLists { ok } }")).to eq(300)
      expect(limit_for("mutation { a: importAnvisaLists { ok } b: importMedicationCatalog { ok } }")).to eq(300)
      expect(limit_for("{ medicationCatalog { currentRelease { id } } }")).to eq(10)
      expect(limit_for("mutation { importMedicationCatalog { ok } revokeMaintenanceToken(id: \"x\") { ok } }")).to eq(10)
      expect(limit_for("mutation { ... on Mutation { importMedicationCatalog { ok } } }")).to eq(10)
    end
  end
end
