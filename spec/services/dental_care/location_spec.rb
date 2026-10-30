require "rails_helper"

# Módulo 28 (ADR 0046; Desvio 6; contrato §16 O25): o <location> do
# procedimento e do item do plano, e os dentes que ele cobre.
RSpec.describe DentalCare::Location do
  def parse(raw) = described_class.parse(raw)
  def location(raw) = parse(raw).payload.fetch(:location)

  it "face com dente e face → ok, na forma completa (dente inteiro, string de dígitos aceita)" do
    result = parse("kind" => "face", "tooth" => 11, "face" => "M")
    expect(result).to be_ok
    expect(result.payload[:location]).to eq(kind: "face", tooth: 11, face: "M", sextant: nil, arch: nil)
    expect(location(kind: "face", tooth: "11", face: "M")).to eq(kind: "face", tooth: 11, face: "M", sextant: nil, arch: nil)
  end

  it "o que falta ou sobra → invalid_location" do
    [
      { kind: "face", tooth: 11 },
      { kind: "face", tooth: 11, face: "X" },
      { kind: "tooth", tooth: 19 },
      { kind: "tooth" },
      { kind: "tooth", tooth: "1a" },
      { kind: "tooth", tooth: 11, face: "M" },
      { kind: "sextant", sextant: "S7" },
      { kind: "sextant", sextant: "S1", tooth: 11 },
      { kind: "arch", arch: "middle" },
      { kind: "mouth", arch: "upper" },
      { kind: "gum" },
      "tooth",
      nil
    ].each do |raw|
      result = parse(raw)
      expect(result).to be_failure, "esperava recusa para #{raw.inspect}"
      expect(result.reason).to eq(:invalid_location)
    end
  end

  it "campos nulos de outro tipo não atrapalham (a forma do dashboard)" do
    expect(location(kind: "mouth", tooth: nil, face: nil, sextant: nil, arch: nil))
      .to eq(kind: "mouth", tooth: nil, face: nil, sextant: nil, arch: nil)
    expect(location("kind" => "sextant", "sextant" => "S2", "tooth" => nil)[:sextant]).to eq("S2")
  end

  it "teeth: arcada superior = 11–18, 21–28, 51–55 e 61–65" do
    upper = location(kind: "arch", arch: "upper")
    expect(described_class.teeth(upper)).to match_array([ *11..18, *21..28, *51..55, *61..65 ])
    expect(described_class.teeth(location(kind: "arch", arch: "lower"))).to match_array([ *31..38, *41..48, *71..75, *81..85 ])
  end

  it "teeth: dente e face → o dente; sextante → os dentes do sextante; boca → todos" do
    expect(described_class.teeth(location(kind: "face", tooth: 36, face: "O"))).to eq([ 36 ])
    expect(described_class.teeth(location(kind: "sextant", sextant: "S2"))).to match_array([ 13, 12, 11, 21, 22, 23, 53, 52, 51, 61, 62, 63 ])
    expect(described_class.teeth(location(kind: "sextant", sextant: "S6"))).to match_array([ 44, 45, 46, 47, 48, 84, 85 ])
    expect(described_class.teeth(location(kind: "mouth")).size).to eq(52)
  end
end
