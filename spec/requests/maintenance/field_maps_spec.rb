require "rails_helper"

# Módulo 24c (ADR 0053; contrato §10; Q19, Q21, Q22, Q24): o maintenance vê a
# situação do mapa de cada cidade e da base, e pede a geração. Plataforma só:
# nenhuma cidade é aberta. Sem TOTP nem step-up, como as importações.
RSpec.describe "Maintenance: mapas de campo", type: :request do
  include ActiveJob::TestHelper

  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "mapa-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let!(:city) { home_visit_city! }

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)
  # A API de manutenção roda fora de qualquer cidade: a fila de destino é a de plataforma.
  def gql!(query) = on_platform_queue { post("/graphql", params: { query: query, variables: "{}" }, headers: browser) }
  def audit(name) = PlatformEvent.where(name: name).order(:created_at).map { |event| event.payload["outcome"] }

  def sign_in!
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
         headers: browser
  end

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
    sign_in!
  end

  it "fieldMaps lista só as cidades com linha, com o estado e o arquivo publicado; sizeBytes grande sai inteiro" do
    expect(Maintenance::CityReader).not_to receive(:call)
    gql!("{ fieldMaps { citySlug } }")
    expect(json.dig("data", "fieldMaps")).to eq([])

    big = 5_000_000_000
    FieldMap.create!(city_id: city.id, state: "failed", error_code: "extract_failed", requested_at: Time.current,
                     version: Date.new(2026, 11, 1), size_bytes: big, sha256: "ab" * 32,
                     storage_key: "field-maps/cities/#{city.id}/2026-11-01-abababababab.pmtiles", built_at: Time.zone.parse("2026-11-02 10:00"))
    gql!("{ fieldMaps { citySlug state version sizeBytes builtAt errorCode } }")
    expect(json.dig("data", "fieldMaps")).to eq([ { "citySlug" => city.slug, "state" => "failed", "version" => "2026-11-01",
                                                    "sizeBytes" => big.to_s, "builtAt" => Time.zone.parse("2026-11-02 10:00").iso8601,
                                                    "errorCode" => "extract_failed" } ])
  end

  it "linha sem arquivo publicado: versão, tamanho e data nulos" do
    FieldMap.create!(city_id: city.id, state: "building", requested_at: Time.current)
    gql!("{ fieldMaps { citySlug state version sizeBytes builtAt errorCode } }")
    expect(json.dig("data", "fieldMaps")).to eq([ { "citySlug" => city.slug, "state" => "building", "version" => nil, "sizeBytes" => nil,
                                                    "builtAt" => nil, "errorCode" => nil } ])
  end

  it "fieldMapBase é null sem base pronta; com base, a versão e a idade em dias" do
    gql!("{ fieldMapBase { version ageDays } }")
    expect(json.dig("data", "fieldMapBase")).to be_nil
    FieldMapBase.create!(version: Time.zone.today - 12, state: "ready", source_url: "https://build.protomaps.com/x.pmtiles",
                         storage_key: "field-maps/base/x.pmtiles", size_bytes: 10, sha256: "ab" * 32, ready_at: Time.current)
    FieldMapBase.create!(version: Time.zone.today, state: "copying", source_url: "https://build.protomaps.com/y.pmtiles")
    gql!("{ fieldMapBase { version ageDays } }")
    expect(json.dig("data", "fieldMapBase")).to eq("version" => (Time.zone.today - 12).iso8601, "ageDays" => 12)
  end

  it "o SDL dos tipos e campos novos é o combinado com o maintenance" do
    sdl = Maintenance::Schema.to_definition
    expect(sdl).to include("type FieldMap {\n  builtAt: ISO8601DateTime\n  citySlug: String!\n  errorCode: String\n  sizeBytes: BigInt\n  state: String!\n  version: ISO8601Date\n}")
    expect(sdl).to include("type FieldMapBase {\n  ageDays: Int!\n  version: ISO8601Date!\n}")
    expect(sdl).to match(/fieldMaps: \[FieldMap!\]!/)
    expect(sdl).to match(/fieldMapBase: FieldMapBase\n/)
    expect(sdl).to match(/buildFieldMap\(citySlug: String!\): BuildFieldMapPayload/)
    expect(sdl).to match(/refreshFieldMapBase: RefreshFieldMapBasePayload/)
    expect(sdl).to include("type BuildFieldMapPayload {\n  errors: [UserError!]!\n  fieldMap: FieldMap\n  ok: Boolean!\n}")
    expect(sdl).to include("type RefreshFieldMapBasePayload {\n  errors: [UserError!]!\n  fieldMapBase: FieldMapBase\n  ok: Boolean!\n}")
  end

  it "buildFieldMap marca building, enfileira o job de plataforma e audita tentativa e resultado; repetir não enfileira de novo" do
    query = %(mutation { buildFieldMap(citySlug: "#{city.slug}") { ok errors { path message } fieldMap { citySlug state errorCode } } })
    expect { gql!(query) }.to have_enqueued_job(FieldMaps::BuildJob).with(city.id).exactly(:once)
    expect(json.dig("data", "buildFieldMap")).to eq("ok" => true, "errors" => [],
                                                    "fieldMap" => { "citySlug" => city.slug, "state" => "building", "errorCode" => nil })
    expect(audit("maintenance.field_map.build_requested")).to eq(%w[attempted ok])
    event = PlatformEvent.where(name: "maintenance.field_map.build_requested").order(:created_at).last
    expect(event.payload).to include("module" => "field_maps", "city_slug" => city.slug, "maintainer_id" => maintainer.id)

    expect { gql!(query) }.not_to have_enqueued_job(FieldMaps::BuildJob)
    expect(json.dig("data", "buildFieldMap", "ok")).to be(true)
  end

  it "slug desconhecido ou cidade que não está ativa → ok false com o path, nada enfileirado e auditoria rejected" do
    expect do
      gql!(%(mutation { buildFieldMap(citySlug: "nao-existe") { ok errors { path message } fieldMap { state } } }))
    end.not_to have_enqueued_job(FieldMaps::BuildJob)
    expect(json.dig("data", "buildFieldMap")).to eq("ok" => false, "errors" => [ { "path" => "citySlug", "message" => "cidade não encontrada" } ],
                                                    "fieldMap" => nil)
    expect(audit("maintenance.field_map.build_requested")).to eq(%w[attempted rejected])
    expect(FieldMap.count).to eq(0)
  end

  it "refreshFieldMapBase enfileira a cópia da base; com uma cópia em curso, recusa" do
    query = "mutation { refreshFieldMapBase { ok errors { path message } fieldMapBase { version ageDays } } }"
    expect { gql!(query) }.to have_enqueued_job(FieldMaps::RefreshBaseJob).exactly(:once)
    expect(json.dig("data", "refreshFieldMapBase")).to eq("ok" => true, "errors" => [], "fieldMapBase" => nil)
    expect(audit("maintenance.field_map.base_refresh_requested")).to eq(%w[attempted ok])

    FieldMapBase.create!(version: Time.zone.today, state: "copying", source_url: "https://build.protomaps.com/y.pmtiles")
    expect { gql!(query) }.not_to have_enqueued_job(FieldMaps::RefreshBaseJob)
    expect(json.dig("data", "refreshFieldMapBase")).to include("ok" => false, "errors" => [ { "path" => "base", "message" => "cópia em curso" } ])
  end

  it "sem sessão de mantenedor não lê nem escreve" do
    delete "/session", headers: browser
    gql!("{ fieldMaps { citySlug } }")
    expect(json["data"]).to be_nil
    expect { gql!(%(mutation { buildFieldMap(citySlug: "#{city.slug}") { ok } })) }.not_to have_enqueued_job(FieldMaps::BuildJob)
    expect(FieldMap.count).to eq(0)
  end
end
