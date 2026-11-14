require "rails_helper"

# Módulo 24c (ADR 0053; Q23, Q32): a base de onde saem os recortes. O job lê o
# índice de builds do Protomaps, recorta a caixa configurada da build mais
# recente com o CLI, guarda no serviço de arquivos e só então descarta a
# anterior. O CLI é simulado: copia o fixture para a saída.
RSpec.describe FieldMaps::RefreshBaseJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let(:fixture) { Rails.root.join("spec/fixtures/field_maps/sample.pmtiles") }
  let(:cache) { Pathname.new(Dir.mktmpdir) }
  let(:index) do
    [ { "key" => "20230918.pmtiles", "size" => 1 }, { "key" => "20261113.pmtiles", "size" => 2 },
      { "key" => "20261114.pmtiles", "size" => 3 }, { "key" => "notas.txt", "size" => 4 } ]
  end

  before do
    allow(FieldMaps::Config).to receive(:cache_dir).and_return(cache)
    stub_request(:get, FieldMaps::Config.builds_index_url).to_return(status: 200, body: index.to_json)
  end

  after do
    FieldMapBase.where.not(storage_key: nil).pluck(:storage_key).each { |key| FieldMaps::Storage.delete(key) }
    FileUtils.rm_rf(cache)
  end

  def cli_copies_fixture
    allow(FieldMaps::Cli).to receive(:extract) do |input:, output:, bbox:, maxzoom:|
      @cli = { input: input, bbox: bbox, maxzoom: maxzoom }
      FileUtils.mkdir_p(File.dirname(output))
      FileUtils.cp(fixture, output)
      Result.ok
    end
  end

  it "índice → a build mais recente → ready, com tamanho, SHA-256 e a chave no serviço de arquivos" do
    cli_copies_fixture
    described_class.perform_now
    base = FieldMapBase.sole
    expect(base).to have_attributes(version: Date.new(2026, 11, 14), state: "ready", error_code: nil,
                                    source_url: "https://build.protomaps.com/20261114.pmtiles",
                                    storage_key: "field-maps/base/2026-11-14.pmtiles", size_bytes: File.size(fixture),
                                    sha256: Digest::SHA256.file(fixture).hexdigest)
    expect(base.ready_at).to be_present
    expect(@cli).to eq(input: "https://build.protomaps.com/20261114.pmtiles", bbox: FieldMaps::Config.base_bbox, maxzoom: 15)
    expect(FieldMaps::Storage.chunk(base.storage_key, 0..6)).to eq("PMTiles".b)
    expect(FieldMapBase.current).to eq(base)
  end

  it "a base anterior sai do serviço de arquivos e da tabela só depois que a nova está pronta" do
    cli_copies_fixture
    old_key = "field-maps/base/2026-10-01.pmtiles"
    FieldMaps::Storage.upload(old_key, fixture)
    old = FieldMapBase.create!(version: Date.new(2026, 10, 1), state: "ready", source_url: "https://build.protomaps.com/20261001.pmtiles",
                               storage_key: old_key, size_bytes: 1, sha256: "ab" * 32, ready_at: 1.month.ago)
    described_class.perform_now
    expect(FieldMapBase.current.version).to eq(Date.new(2026, 11, 14))
    expect(FieldMapBase.exists?(old.id)).to be(false)
    expect(FieldMaps::Storage.exist?(old_key)).to be(false)
  end

  it "a build mais recente já é a base pronta → nada a fazer" do
    cli_copies_fixture
    described_class.perform_now
    expect { described_class.perform_now }.not_to change { FieldMapBase.sole.attributes }
    expect(FieldMaps::Cli).to have_received(:extract).once
  end

  it "índice indisponível ou sem build → failed base_missing, e a base pronta anterior continua" do
    cli_copies_fixture
    described_class.perform_now
    ready = FieldMapBase.sole
    [ { status: 503, body: "" }, { status: 200, body: "não é json" }, { status: 200, body: [].to_json } ].each do |response|
      stub_request(:get, FieldMaps::Config.builds_index_url).to_return(**response)
      travel_to(Date.new(2026, 12, 1)) { described_class.perform_now }
      failed = FieldMapBase.find_by!(version: Date.new(2026, 12, 1))
      expect(failed).to have_attributes(state: "failed", error_code: "base_missing", storage_key: nil)
    end
    expect(FieldMapBase.current).to eq(ready)
    expect(FieldMaps::Storage.exist?(ready.storage_key)).to be(true)
  end

  it "o CLI falha → failed extract_failed, sem arquivo e sem tocar a base anterior" do
    allow(FieldMaps::Cli).to receive(:extract).and_return(Result.fail(:extract_failed))
    described_class.perform_now
    expect(FieldMapBase.sole).to have_attributes(version: Date.new(2026, 11, 14), state: "failed", error_code: "extract_failed", storage_key: nil)
    expect(Dir[cache.join("**/*.pmtiles").to_s]).to be_empty

    cli_copies_fixture
    described_class.perform_now # nova tentativa da mesma versão
    expect(FieldMapBase.sole).to have_attributes(state: "ready", error_code: nil)
  end

  it "com uma cópia em curso, não começa outra" do
    FieldMapBase.create!(version: Date.new(2026, 11, 14), state: "copying", source_url: "https://build.protomaps.com/20261114.pmtiles")
    cli_copies_fixture
    described_class.perform_now
    expect(FieldMaps::Cli).not_to have_received(:extract)
  end
end
