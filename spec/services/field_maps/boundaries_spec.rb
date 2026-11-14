require "rails_helper"

# Módulo 24c (ADR 0053; Q33): a caixa de cada município vem do arquivo
# vendorizado do IBGE; o recorte soma 2 km de margem em volta.
RSpec.describe FieldMaps::Boundaries, type: :model do
  it "o CSV é o do SOURCE: SHA-256, cabeçalho e os 5.570 municípios" do
    csv = Rails.root.join("vendor/ibge/2026-11-13/municipios_bbox.csv")
    source = Rails.root.join("vendor/ibge/2026-11-13/SOURCE").read
    expect(source).to include("SHA-256: #{Digest::SHA256.file(csv).hexdigest}")
    lines = csv.readlines(chomp: true)
    expect(lines.first).to eq("ibge_code,min_lon,min_lat,max_lon,max_lat")
    expect(lines.size - 1).to eq(5570)
    expect(lines.drop(1)).to all(match(/\A\d{7}(,-?\d+\.\d{5}){4}\z/))
  end

  it "Curitiba e Maringá têm caixa; código desconhecido, não" do
    expect(described_class.bbox("4106902")).to eq([ -49.3893, -25.6432, -49.1852, -25.3451 ])
    expect(described_class.bbox("4115200")).to eq([ -52.1003, -23.5566, -51.8366, -23.2539 ])
    expect(described_class.bbox(4106902)).to eq(described_class.bbox("4106902"))
    expect(described_class.bbox("9999999")).to be_nil
    expect(described_class.bbox(nil)).to be_nil
    expect(described_class.bbox("")).to be_nil
  end

  it "a margem de 2 km vale em latitude e, corrigida pela latitude, em longitude" do
    box = described_class.bbox("4106902")
    wide = described_class.with_margin(box)
    lat = 2 / 111.32
    lon = 2 / (111.32 * Math.cos((box[1] + box[3]) / 2 * Math::PI / 180))
    expect(wide).to eq([ (box[0] - lon).round(5), (box[1] - lat).round(5), (box[2] + lon).round(5), (box[3] + lat).round(5) ])
    expect(wide[2] - box[2]).to be > (wide[3] - box[3]) # longe do equador, o grau de longitude é mais curto
    expect(described_class.with_margin(box, km: 0)).to eq(box)
  end

  it "a margem não passa dos limites do globo" do
    expect(described_class.with_margin([ -179.999, -89.999, 179.999, 89.999 ])).to eq([ -180.0, -90.0, 180.0, 90.0 ])
  end
end
