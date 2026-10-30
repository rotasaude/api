require "rails_helper"

# Módulo 28 (ADR 0046; Desvio 5): o efeito de cada SIGTAP no odontograma.
RSpec.describe DentalCare::SigtapSituations do
  def loc(raw) = DentalCare::Location.parse(raw).payload.fetch(:location)

  it "o YAML lista os 22 códigos do Desvio 5, com nome e source" do
    yaml = YAML.load_file(Rails.root.join("config/dental/sigtap_situations.yml"))
    expect(yaml.fetch("version")).to eq(1)
    expect(described_class.codes).to match_array(%w[0307010031 0307010074 0307010082 0307010090 0307010104 0307010112 0307010120
                                                    0307010139 0101020066 0414020120 0414020138 0307020037 0307020045 0307020053
                                                    0307020061 0701070145 0701070153 0701070129 0701070137 0701070099 0701070102
                                                    0701070110])
    yaml.fetch("procedures").each_value do |row|
      expect(row.values_at("name", "source")).to all(be_present)
      expect(row.fetch("name")).to eq(DentalHelpers::SIGTAP.fetch(yaml["procedures"].key(row)))
    end
  end

  it "restauração: na face quando o local é face, senão na coroa" do
    expect(described_class.effects("0307010031", loc(kind: "face", tooth: 11, face: "M")))
      .to eq([ { tooth: 11, part: "crown", face: "M", situation: "restored" } ])
    expect(described_class.effects("0307010120", loc(kind: "tooth", tooth: 36)))
      .to eq([ { tooth: 36, part: "crown", face: nil, situation: "restored" } ])
  end

  it "exodontia → extracted na coroa; endodontia → endodontics na raiz; implante → raiz e coroa" do
    expect(described_class.effects("0414020138", loc(kind: "tooth", tooth: 36)))
      .to eq([ { tooth: 36, part: "crown", face: nil, situation: "extracted" } ])
    expect(described_class.effects("0307020061", loc(kind: "tooth", tooth: 11)))
      .to eq([ { tooth: 11, part: "root", face: nil, situation: "endodontics" } ])
    expect(described_class.effects("0701070153", loc(kind: "tooth", tooth: 46)))
      .to eq([ { tooth: 46, part: "root", face: nil, situation: "implant" },
               { tooth: 46, part: "crown", face: nil, situation: "crown_unit_prosthesis" } ])
  end

  it "prótese total na arcada: complete_denture em cada dente permanente da arcada (nunca no decíduo)" do
    effects = described_class.effects("0701070137", loc(kind: "arch", arch: "upper"))
    expect(effects.map { |e| e[:tooth] }).to match_array([ *11..18, *21..28 ])
    expect(effects.map { |e| e.except(:tooth) }.uniq).to eq([ { part: "crown", face: nil, situation: "complete_denture" } ])
  end

  it "PPR: só nos dentes ausentes ou extraídos da arcada (exige o odontograma) e nunca no decíduo" do
    chart = { teeth: [ { tooth: 36, situation: "extracted" }, { tooth: 46, situation: "missing" }, { tooth: 75, situation: "missing" },
                       { tooth: 37, situation: "caries" }, { tooth: 16, situation: "missing" } ] }
    effects = described_class.effects("0701070099", loc(kind: "arch", arch: "lower"), chart: chart)
    expect(effects).to eq([ { tooth: 36, part: "crown", face: nil, situation: "removable_partial_denture" },
                            { tooth: 46, part: "crown", face: nil, situation: "removable_partial_denture" } ])
    expect { described_class.effects("0701070099", loc(kind: "arch", arch: "lower")) }.to raise_error(ArgumentError)
  end

  it "decíduo não recebe prótese coronária; local fora do efeito ou código fora da tabela → []" do
    expect(described_class.effects("0701070145", loc(kind: "tooth", tooth: 54))).to eq([])
    expect(described_class.effects("0307010031", loc(kind: "mouth"))).to eq([])
    expect(described_class.effects("0101020074", loc(kind: "mouth"))).to eq([])
  end

  it "locations: o local do efeito de cada código" do
    expect(described_class.locations("0307010031")).to eq(%w[tooth face])
    expect(described_class.locations("0701070129")).to eq(%w[arch])
    expect(described_class.locations("0101020074")).to eq([])
  end
end
