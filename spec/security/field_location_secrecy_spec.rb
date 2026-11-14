require "rails_helper"

# Módulo 24c (ADR 0053; contrato §4, §3.1; Q2, Q14, Q19, Q29, Q34, Q63): o
# sigilo da coordenada do imóvel e da visita, de ponta a ponta, pelas rotas
# reais. A coordenada diz onde a pessoa mora e onde foi visitada: vai ao banco
# (cifrada), ao próprio app e ao mapa do dashboard — e a mais nenhum lugar.
#
# Cenário: o aparelho envia um domicílio com ponto, uma família nova e uma
# visita com GPS, e três itens com coordenada inválida; o dashboard corrige o
# ponto pelo PATCH (um aceito, um recusado); o app baixa as mudanças, a
# referência e o mapa (inteiro, intervalo, 416); o dashboard lê os pontos da
# microárea; o job gera o mapa da cidade.
# Provas de ausência: log, eventos de domínio e de plataforma, recusas, query,
# cursor do download, linhas do mapa e chaves de cache. Fora do cenário: os
# nomes de evento de plataforma do módulo.
module FieldLocationSecrecy
  # Valores únicos do cenário (texto com 4+ casas, como iriam a um log).
  LATITUDES = [ -25.42847123, -25.41936552, -25.40718834, -25.428471234, -25.43365911 ].freeze
  LONGITUDES = [ -49.27325411, -49.26814477, -49.31839266, -49.25590133 ].freeze
  NEEDLES = (LATITUDES + LONGITUDES).map { |value| value.abs.to_s[0, 7] }.uniq.freeze
  KEYS = %w[location latitude longitude accuracy_m].freeze
  PLATFORM_EVENTS = %w[field_map.built field_map.failed maintenance.field_map.build_requested
                       maintenance.field_map.base_refresh_requested].freeze

  def self.keys_in(value)
    case value
    when Hash then value.flat_map { |key, inner| [ key.to_s ] + keys_in(inner) }
    when Array then value.flat_map { |inner| keys_in(inner) }
    else []
    end
  end
end

RSpec.describe "Sigilo da coordenada (24c) — cenário completo", type: :request do
  let!(:city) { home_visit_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let!(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let(:token) { FieldDevices::Register.call(user: acs, name: "Tablet").payload.fetch(:token) }
  let(:cache_keys) { [] }

  def point(index, **over) = { "latitude" => FieldLocationSecrecy::LATITUDES[index], "longitude" => FieldLocationSecrecy::LONGITUDES[index % 4],
                               "accuracy_m" => 8.5, "source" => "gps" }.merge(over.stringify_keys)
  def bearer = { "Authorization" => "Bearer #{token}" }
  def item(type, body, uuid: SecureRandom.uuid) = { "client_uuid" => uuid, "type" => type, "body" => body }

  def household_body(**over)
    { "micro_area_id" => area.id, "property_type" => "1", "refused" => false, "address" => registry_address,
      "living_conditions" => registry_living_conditions }.merge(over.stringify_keys)
  end

  def visit_body(**over)
    { "team_id" => team.id, "occurred_at" => Time.current.change(usec: 0).iso8601, "micro_area_id" => area.id, "property_type" => "1",
      "subject" => "none", "outcome" => 1, "reasons" => [ 1 ], "shared" => false }.merge(over.stringify_keys)
  end

  # Roda o cenário inteiro e devolve o que as provas leem.
  def scenario
    responses = []
    keep = ->(label) { responses << [ label, response.status, response.body.dup ] }
    allow(Rails.cache).to receive(:fetch).and_wrap_original { |original, key, *args, **opts, &block| cache_keys << key.to_s; original.call(key, *args, **opts, &block) }
    allow(Rails.cache).to receive(:write).and_wrap_original { |original, key, *args, **opts| cache_keys << key.to_s; original.call(key, *args, **opts) }
    allow(FieldMaps::Config).to receive(:cache_dir).and_return(Pathname.new(Dir.mktmpdir))
    allow(FieldMaps::Cli).to receive(:extract) do |output:, **|
      FileUtils.cp(FieldMapHelpers::FIELD_MAP_FIXTURE, output)
      Result.ok
    end

    household_uuid, family_uuid = SecureRandom.uuid, SecureRandom.uuid
    log = capture_log do
      # O aparelho envia: domicílio com ponto, família nova, visita com GPS e três recusas de coordenada.
      post "/field/v1/uploads", headers: bearer.merge("Content-Type" => "application/json"), params: { items: [
        item("household", household_body(location: point(0)), uuid: household_uuid),
        item("family", { "household_client_uuid" => household_uuid, "version" => 1, "responsible" => { "patient_id" => registry_patient!.id },
                         "income_band" => "3", "members_count" => 1, "living_since" => "2026-11" }, uuid: family_uuid),
        item("home_visit", visit_body(location: point(1))),
        item("household", household_body(location: point(3))),                       # 9 casas
        item("home_visit", visit_body(location: point(2).except("accuracy_m"))),     # GPS sem precisão
        item("home_visit", visit_body(location: point(2, source: "map")))            # ponto do mapa na visita
      ] }.to_json
      keep.call(:upload)
      @results = JSON.parse(response.body).fetch("results")
      household_id = @results.first.fetch("id")

      # O dashboard corrige o ponto (aceito) e erra (recusado).
      sign_in_as(acs)
      patch_body = registry_household_params(Household.find(household_id)).merge("version" => 2)
      json_patch "/territory/households/#{household_id}", patch_body.merge("location" => point(2).except("accuracy_m").merge("source" => "map"))
      keep.call(:patch_ok)
      json_patch "/territory/households/#{household_id}", patch_body.merge("version" => 3, "location" => point(4).merge("latitude" => "aqui"))
      keep.call(:patch_refused)
      get "/territory/map/households", params: { micro_area_id: area.id }
      keep.call(:points)

      # O app baixa mudanças, referência e mapa.
      travel 10.seconds do
        get "/field/v1/changes", headers: bearer
        keep.call(:changes)
        @cursor = JSON.parse(response.body).fetch("next_cursor")
      end
      get "/field/v1/reference", headers: bearer
      keep.call(:reference)
      get "/field/v1/map", headers: bearer
      keep.call(:map_missing)

      # O job gera o mapa da cidade a partir de uma base pronta.
      base_key = "field-maps/base/2026-11-14.pmtiles"
      FieldMaps::Storage.upload(base_key, FieldMapHelpers::FIELD_MAP_FIXTURE)
      (@field_map_keys ||= []) << base_key
      FieldMapBase.create!(version: Date.new(2026, 11, 14), state: "ready", source_url: "https://build.protomaps.com/20261114.pmtiles",
                           storage_key: base_key, size_bytes: field_map_bytes.bytesize, sha256: field_map_sha, ready_at: Time.current)
      city_profile!
      FieldMaps::BuildJob.perform_now(city.id)
      @field_map_keys << FieldMap.find_by!(city_id: city.id).storage_key
      get "/field/v1/map", headers: bearer.merge("Range" => "bytes=0-6")
      keep.call(:map_range)
      get "/field/v1/map", headers: bearer.merge("Range" => "bytes=99999999-")
      keep.call(:map_416)
      get "/field/v1/session", headers: bearer
      keep.call(:session)
    end
    { log: log, responses: responses.to_h { |label, status, body| [ label, [ status, body ] ] } }
  end

  include ActiveSupport::Testing::TimeHelpers

  it "o cenário grava o que devia, e a coordenada não vai a log, evento, recusa, cursor, cache nem ao mapa" do
    outcome = scenario
    responses = outcome.fetch(:responses)

    # O cenário rodou de verdade: três aceitos, três recusados pela coordenada, com o path.
    expect(@results.map { _1["status"] }).to eq(%w[accepted accepted accepted rejected rejected rejected])
    expect(@results.last(3).map { _1.slice("error", "path") }).to eq([
      { "error" => "invalid_location", "path" => "location.latitude" },
      { "error" => "invalid_location", "path" => "location.accuracy_m" },
      { "error" => "invalid_location", "path" => "location.source" }
    ])
    expect(responses.transform_values(&:first)).to eq(upload: 200, patch_ok: 200, patch_refused: 422, points: 200, changes: 200,
                                                      reference: 200, map_missing: 404, map_range: 206, map_416: 416, session: 200)
    household = Household.find(@results.first.fetch("id"))
    expect(household.latest_version.location).to include("latitude" => FieldLocationSecrecy::LATITUDES[2], "source" => "map")
    expect(HomeVisit.sole.location).to include("latitude" => FieldLocationSecrecy::LATITUDES[1])

    # Quem pode ver vê: o próprio app e o mapa do dashboard.
    expect(responses.fetch(:points).last).to include(FieldLocationSecrecy::LATITUDES[2].to_s)
    expect(responses.fetch(:changes).last).to include(FieldLocationSecrecy::LATITUDES[2].to_s)

    # Log: nenhuma coordenada do cenário, nem o token.
    log = outcome.fetch(:log)
    expect(FieldLocationSecrecy::NEEDLES.select { |needle| log.include?(needle) }).to eq([])
    expect(log).not_to include(token)
    expect(log).not_to include("aqui")

    # Eventos de domínio e de plataforma: nenhuma chave de coordenada, em nenhuma profundidade, e nenhum valor.
    events = DomainEvent.all.to_a + PlatformEvent.all.to_a
    expect(events).not_to be_empty
    offenders = events.select { |event| (FieldLocationSecrecy.keys_in(event.payload) & FieldLocationSecrecy::KEYS).any? }
    expect(offenders.map(&:name)).to eq([])
    payloads = events.map { |event| event.payload.to_json }.join
    expect(FieldLocationSecrecy::NEEDLES.select { |needle| payloads.include?(needle) }).to eq([])
    expect(PlatformEvent.where("name LIKE 'field_map.%'").pluck(:name)).to eq([ "field_map.built" ])
    expect(PlatformEvent.find_by!(name: "field_map.built").payload.keys).to match_array(%w[city_id version size_bytes sha256])

    # Recusas: só código e path, nunca o valor enviado.
    refusals = [ @results.last(3).to_json, responses.fetch(:patch_refused).last, responses.fetch(:map_missing).last, responses.fetch(:map_416).last ]
    refusals.each do |body|
      expect(FieldLocationSecrecy::NEEDLES.select { |needle| body.include?(needle) }).to eq([])
      expect(body).not_to include("aqui")
    end
    expect(JSON.parse(responses.fetch(:patch_refused).last)).to eq("error" => "invalid_location", "path" => "location.latitude")
    expect(JSON.parse(responses.fetch(:map_416).last)).to eq("error" => "range_not_satisfiable")

    # Cursor do download: só escopo, instante e id.
    cursor = Base64.urlsafe_decode64(@cursor)
    expect(FieldLocationSecrecy::NEEDLES.select { |needle| cursor.include?(needle) }).to eq([])
    expect(FieldLocationSecrecy::KEYS.select { |key| cursor.include?(key) }).to eq([])

    # Mapa: as linhas de plataforma e o arquivo não têm id de domicílio nem de pessoa.
    platform_rows = (FieldMap.all.map(&:attributes) + FieldMapBase.all.map(&:attributes)).to_json
    people_and_homes = [ household.id, acs.id, acs.professional.id ] + Patient.pluck(:id)
    expect(people_and_homes.select { |id| platform_rows.include?(id) }).to eq([])
    expect(FieldMaps::Storage.chunk(FieldMap.find_by!(city_id: city.id).storage_key, 0..6)).to eq("PMTiles".b)

    # Cache: nenhuma chave com coordenada, nome ou id de pessoa.
    keys = cache_keys.join("\n")
    expect(FieldLocationSecrecy::NEEDLES.select { |needle| keys.include?(needle) }).to eq([])
    expect(keys).not_to include(acs.professional.professional_name)
    expect(cache_keys.grep(/field_sync\/reference_version/)).not_to be_empty
  end

  it "nenhuma rota do mapa ou da referência aceita coordenada na query" do
    published_field_map!(city)
    query = { latitude: "-25.42847123", longitude: "-49.27325411" }
    [ "/field/v1/map", "/field/v1/reference", "/field/v1/session" ].each do |path|
      get path, params: query, headers: bearer
      expect([ path, response.status, response.body ]).to eq([ path, 422, { error: "invalid_request" }.to_json ])
    end
    sign_in_as(acs)
    get "/territory/map", params: query
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    get "/territory/map/households", params: query.merge(micro_area_id: area.id)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    get "/territory/households", params: query.merge(micro_area_id: area.id)
    expect(response.body).not_to include("25.428")
  end
end

RSpec.describe "Sigilo da coordenada (24c) — eventos de plataforma do módulo", type: :model do
  # Varredura do texto inteiro (a chamada quebra linha depois do parêntese).
  def names(pattern, *globs)
    globs.flat_map { |glob| Dir[Rails.root.join(glob).to_s] }.flat_map do |file|
      File.read(file, encoding: "utf-8").scan(pattern).flatten
    end.uniq.sort
  end

  it "o módulo publica exatamente os quatro nomes, todos no R18 e no catálogo" do
    direct = names(/Platform\.audit\(\s*"([a-z_.]+)"/m, "app/jobs/field_maps/*.rb", "app/services/field_maps/*.rb")
    # `audited(event:)` nas mutations de plataforma e `on_platform(…, event:)` nas de cidade (CityMutation).
    audited = names(/\b(?:audited|on_platform|in_city)\([^)]*?\bevent:\s*"([a-z_.]+)"/m, "app/graphql/maintenance/mutations/*field_map*.rb")
    expect(direct).to eq(FieldMaps::Catalog::EVENTS.sort)
    expect(audited).to eq(FieldMaps::Catalog::AUDIT.sort)
    expect((direct + audited).sort).to eq(FieldLocationSecrecy::PLATFORM_EVENTS.sort)
    expect(MaintenanceAudit::NAMES).to include(*audited)

    guard = File.read(Rails.root.join("spec/events/platform_event_payload_guard_spec.rb"), encoding: "utf-8")
    r18 = guard[/R18_PLATFORM_EVENT_NAMES = %w\[(.*?)\]\.freeze/m, 1].to_s.split
    expect(r18).to include(*FieldLocationSecrecy::PLATFORM_EVENTS)
  end

  it "nenhum evento de domínio do módulo leva a coordenada: os comandos publicam só ids" do
    sources = %w[app/commands/territory_registry/save_household.rb app/commands/home_visits/record.rb app/services/field_sync/upload.rb
                 app/services/territory_registry/trail.rb app/controllers/territory_registry/maps_controller.rb]
    sources.each do |file|
      File.read(Rails.root.join(file), encoding: "utf-8").scan(/DomainEvents\.publish\((.*?)\)\s*$/m).flatten.each do |call|
        expect(call).not_to match(/\b(location|latitude|longitude|accuracy_m)\b/), file
      end
    end
  end
end
