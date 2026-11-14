require "rails_helper"

# Módulo 24c (ADR 0053; contrato §3.1; Q24, Q30–Q33): o recorte do mapa de uma
# cidade a partir da base guardada. A caixa vem do IBGE da cidade mais 2 km; o
# arquivo publicado só troca quando o novo já está no serviço de arquivos, e o
# antigo só sai depois. O CLI é simulado: grava na saída o conteúdo combinado.
RSpec.describe FieldMaps::BuildJob, type: :job do
  let!(:city) { home_visit_city! }
  let(:fixture) { Rails.root.join("spec/fixtures/field_maps/sample.pmtiles") }
  let(:cache) { Pathname.new(Dir.mktmpdir) }
  let(:base_key) { "field-maps/base/2026-11-14.pmtiles" }
  let(:sha) { Digest::SHA256.file(fixture).hexdigest }

  before do
    allow(FieldMaps::Config).to receive(:cache_dir).and_return(cache)
    city_profile!
  end

  after do
    (FieldMap.where.not(storage_key: nil).pluck(:storage_key) + [ base_key ]).each { |key| FieldMaps::Storage.delete(key) }
    FileUtils.rm_rf(cache)
  end

  def base!
    FieldMaps::Storage.upload(base_key, fixture)
    FieldMapBase.create!(version: Date.new(2026, 11, 14), state: "ready", source_url: "https://build.protomaps.com/20261114.pmtiles",
                         storage_key: base_key, size_bytes: File.size(fixture), sha256: sha, ready_at: Time.current)
  end

  # O CLI simulado: grava `content` (ou o fixture) na saída e guarda os argumentos.
  def cli_writes(content = nil)
    allow(FieldMaps::Cli).to receive(:extract) do |input:, output:, bbox:, maxzoom:|
      @cli = { input: input.to_s, bbox: bbox, maxzoom: maxzoom }
      content ? File.binwrite(output, content) : FileUtils.cp(fixture, output)
      Result.ok
    end
  end

  def events(name) = PlatformEvent.where(name: name).order(:created_at)
  def map = FieldMap.find_by!(city_id: city.id)

  it "recorta a caixa do IBGE mais 2 km, publica e audita só com cidade, versão, tamanho e SHA" do
    base!
    cli_writes
    described_class.perform_now(city.id)

    expect(map).to have_attributes(state: "ready", error_code: nil, version: Date.new(2026, 11, 14), size_bytes: File.size(fixture), sha256: sha,
                                   storage_key: "field-maps/cities/#{city.id}/2026-11-14-#{sha[0, 12]}.pmtiles")
    expect(map.built_at).to be_present
    expect(map.manifest).to eq(version: "2026-11-14", size_bytes: File.size(fixture), sha256: sha)
    expect(FieldMaps::Storage.chunk(map.storage_key, 0..6)).to eq("PMTiles".b)

    ibge_code = CityProfile.current.ibge_code
    expect(FieldMaps::Boundaries.bbox(ibge_code)).to be_present
    expect(@cli[:bbox]).to eq(FieldMaps::Boundaries.with_margin(FieldMaps::Boundaries.bbox(ibge_code)))
    expect(@cli[:maxzoom]).to eq(15)
    expect(@cli[:input]).to eq(cache.join("base/2026-11-14.pmtiles").to_s)
    expect(Digest::SHA256.file(@cli[:input]).hexdigest).to eq(sha) # a base veio do serviço de arquivos para o cache local

    expect(events("field_map.built").sole.payload).to eq("city_id" => city.id, "version" => "2026-11-14",
                                                         "size_bytes" => File.size(fixture), "sha256" => sha)
    expect(events("field_map.failed")).to be_empty
  end

  it "sem base pronta → failed base_missing e field_map.failed (Q24)" do
    cli_writes
    described_class.perform_now(city.id)
    expect(map).to have_attributes(state: "failed", error_code: "base_missing", storage_key: nil)
    expect(events("field_map.failed").sole.payload).to eq("city_id" => city.id, "error_code" => "base_missing")
    expect(FieldMaps::Cli).not_to have_received(:extract)
  end

  it "cidade sem IBGE ou com IBGE fora do arquivo → failed boundary_missing" do
    base!
    cli_writes
    CityProfile.current.update!(ibge_code: "9999999")
    described_class.perform_now(city.id)
    expect(map).to have_attributes(state: "failed", error_code: "boundary_missing")
    CityProfile.current.destroy!
    described_class.perform_now(city.id)
    expect(map.reload).to have_attributes(state: "failed", error_code: "boundary_missing")
    expect(events("field_map.failed").count).to eq(2)
    expect(FieldMaps::Cli).not_to have_received(:extract)
  end

  # Review Focus 1: o app nunca fica sem o arquivo que estava baixando.
  it "regerar com conteúdo diferente: o publicado só muda no fim e o objeto antigo só sai depois" do
    base!
    cli_writes
    described_class.perform_now(city.id)
    old_key = map.storage_key

    seen = nil
    allow(FieldMaps::Storage).to receive(:delete).and_wrap_original do |original, key|
      seen = { published: FieldMap.find_by!(city_id: city.id).storage_key, new_exists: FieldMaps::Storage.exist?(FieldMap.find_by!(city_id: city.id).storage_key) } if key == old_key
      original.call(key)
    end
    cli_writes("PMTiles\x03 outro conteudo".b)
    map.update!(state: "building", requested_at: Time.current)
    described_class.perform_now(city.id)

    new_sha = Digest::SHA256.hexdigest("PMTiles\x03 outro conteudo".b)
    expect(map.reload).to have_attributes(state: "ready", sha256: new_sha, storage_key: "field-maps/cities/#{city.id}/2026-11-14-#{new_sha[0, 12]}.pmtiles")
    expect(seen).to eq(published: map.storage_key, new_exists: true)
    expect(FieldMaps::Storage.exist?(old_key)).to be(false)
    expect(events("field_map.built").count).to eq(2)
  end

  it "regerar com o mesmo conteúdo não sobe nem apaga nada" do
    base!
    cli_writes
    described_class.perform_now(city.id)
    key = map.storage_key
    built_at = map.built_at
    allow(FieldMaps::Storage).to receive(:upload).and_call_original
    allow(FieldMaps::Storage).to receive(:delete).and_call_original
    map.update!(state: "building", requested_at: Time.current)
    described_class.perform_now(city.id)
    expect(FieldMaps::Storage).not_to have_received(:upload)
    expect(FieldMaps::Storage).not_to have_received(:delete)
    expect(map.reload).to have_attributes(state: "ready", storage_key: key)
    expect(map.built_at).to be >= built_at
  end

  it "o CLI falha ou estoura → failed extract_failed, o publicado anterior continua e nada temporário sobra" do
    base!
    cli_writes
    described_class.perform_now(city.id)
    published = map.manifest
    key = map.storage_key

    allow(FieldMaps::Cli).to receive(:extract).and_return(Result.fail(:extract_failed))
    described_class.perform_now(city.id)
    expect(map.reload).to have_attributes(state: "failed", error_code: "extract_failed", storage_key: key)
    expect(map.manifest).to eq(published)

    allow(FieldMaps::Cli).to receive(:extract).and_raise(RuntimeError, "segredo na mensagem")
    log = capture_log { described_class.perform_now(city.id) }
    expect(map.reload).to have_attributes(state: "failed", error_code: "extract_failed")
    expect(log).not_to include("segredo")
    expect(FieldMaps::Storage.exist?(key)).to be(true)
    expect(events("field_map.failed").last.payload).to eq("city_id" => city.id, "error_code" => "extract_failed")
    expect(Dir[cache.join("tmp/**/*").to_s]).to be_empty
  end

  it "a base do cache local que não bate com o SHA-256 é baixada de novo (Q32)" do
    base!
    cli_writes
    FileUtils.mkdir_p(cache.join("base"))
    File.binwrite(cache.join("base/2026-11-14.pmtiles"), "lixo")
    described_class.perform_now(city.id)
    expect(map.state).to eq("ready")
    expect(Digest::SHA256.file(cache.join("base/2026-11-14.pmtiles")).hexdigest).to eq(sha)
  end

  describe FieldMaps::Request do
    include ActiveJob::TestHelper

    it "build! marca building e enfileira uma vez; já em building não enfileira de novo" do
      expect { @map = on_platform_queue { described_class.build!(city) } }.to have_enqueued_job(FieldMaps::BuildJob).with(city.id)
      expect(@map).to have_attributes(city_id: city.id, state: "building", error_code: nil)
      expect { on_platform_queue { described_class.build!(city) } }.not_to have_enqueued_job(FieldMaps::BuildJob)
      @map.update!(state: "failed", error_code: "extract_failed")
      expect { on_platform_queue { described_class.build!(city) } }.to have_enqueued_job(FieldMaps::BuildJob)
      expect(@map.reload).to have_attributes(state: "building", error_code: nil)
    end

    it "refresh_base! enfileira, salvo com uma cópia em curso" do
      expect { expect(on_platform_queue { described_class.refresh_base! }).to be(true) }.to have_enqueued_job(FieldMaps::RefreshBaseJob)
      FieldMapBase.create!(version: Date.new(2026, 11, 14), state: "copying", source_url: "https://build.protomaps.com/20261114.pmtiles")
      expect { expect(on_platform_queue { described_class.refresh_base! }).to be(false) }.not_to have_enqueued_job(FieldMaps::RefreshBaseJob)
    end
  end

  it "os dois jobs são de plataforma" do
    expect(PlatformQueue::JOBS).to include("FieldMaps::BuildJob", "FieldMaps::RefreshBaseJob")
  end
end
