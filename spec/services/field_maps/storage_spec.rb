require "rails_helper"

# Módulo 24c (ADR 0053): o arquivo de mapa é um objeto no serviço do Active
# Storage, escrito e lido por chave, sem ActiveStorage::Blob (nada em
# active_storage_blobs) e sem ler o objeto inteiro para servir um intervalo.
RSpec.describe FieldMaps::Storage, type: :model do
  let(:fixture) { Rails.root.join("spec/fixtures/field_maps/sample.pmtiles") }
  let(:key) { "field-maps/cities/#{SecureRandom.uuid}/2026-11-01-abababababab.pmtiles" }

  after { described_class.delete(key) }

  it "o fixture é um PMTiles v3" do
    expect(File.binread(fixture, 8).bytes).to eq("PMTiles".bytes + [ 3 ])
  end

  it "upload, intervalo do começo e do fim, download para arquivo e delete" do
    expect(described_class.exist?(key)).to be(false)
    expect { described_class.upload(key, fixture) }.not_to change(ActiveStorage::Blob, :count)
    expect(described_class.exist?(key)).to be(true)

    size = File.size(fixture)
    expect(described_class.chunk(key, 0..6)).to eq("PMTiles".b)
    expect(described_class.chunk(key, (size - 16)..(size - 1))).to eq(File.binread(fixture, 16, size - 16))

    Dir.mktmpdir do |dir|
      target = File.join(dir, "copy.pmtiles")
      described_class.fetch_to(key, target)
      expect(Digest::SHA256.file(target).hexdigest).to eq(Digest::SHA256.file(fixture).hexdigest)
    end

    described_class.delete(key)
    expect(described_class.exist?(key)).to be(false)
    expect { described_class.delete(key) }.not_to raise_error
  end
end
