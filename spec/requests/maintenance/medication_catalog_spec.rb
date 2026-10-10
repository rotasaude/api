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
end
