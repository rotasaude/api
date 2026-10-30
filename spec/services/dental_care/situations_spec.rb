require "rails_helper"

# Módulo 28 (ADR 0046; Desvio 4; contrato §16 O3): as situações do odontograma
# do PEC (coroa, raiz e arcada), as que valem na face e as restrições por dente.
RSpec.describe DentalCare::Situations do
  let(:yaml) { YAML.load_file(Rails.root.join("config/dental/situations.yml")) }

  it "o YAML tem as 21 de coroa, 6 de raiz e 1 de arcada do Desvio 4, cada uma com source" do
    rows = yaml.fetch("situations")
    expect(yaml.fetch("version")).to eq(1)
    by_part = rows.group_by { |row| row.fetch("part") }.transform_values { |list| list.map { |row| row.fetch("code") } }
    expect(by_part.fetch("crown")).to eq(%w[none removable_partial_denture crown_unit_prosthesis temporary_prosthesis missing
                                            calculus caries crown extraction_indicated extracted fracture sound sound_sealed
                                            unerupted active_white_spot abutment restored restored_with_caries residual_root
                                            gingival_recession sealant_indicated])
    expect(by_part.fetch("root")).to eq(%w[none root_caries endodontics implant post furcation_lesion])
    expect(by_part.fetch("arch")).to eq(%w[complete_denture])
    expect(rows.map { |row| row["source"] }).to all(be_present)
    expect(rows.map { |row| row["label"] }).to all(be_present)
    faces = rows.select { |row| row["face"] }.map { |row| row["code"] }
    expect(faces).to match_array(%w[caries restored restored_with_caries fracture active_white_spot sealant_indicated sound_sealed])
    no_deciduous = rows.select { |row| row["part"] == "crown" && !row["deciduous"] }.map { |row| row["code"] }
    expect(no_deciduous).to match_array(%w[crown abutment removable_partial_denture crown_unit_prosthesis temporary_prosthesis])
    expect(rows.find { |row| row["code"] == "caries" }["abbr"]).to eq("C")
  end

  it "list(part): { code, label, abbr }" do
    expect(described_class.list("crown").size).to eq(21)
    expect(described_class.list("root").map { |s| s[:code] }).to eq(%w[none root_caries endodontics implant post furcation_lesion])
    expect(described_class.list("arch")).to eq([ { code: "complete_denture", label: "Prótese total", abbr: nil } ])
    expect(described_class.list("crown")).to include(code: "restored_with_caries", label: "Restaurado com cárie", abbr: "Rc")
    expect(described_class.list("face").map { |s| s[:code] })
      .to eq(%w[caries fracture sound_sealed active_white_spot restored restored_with_caries sealant_indicated])
  end

  it "cárie na face M do 11 é válida" do
    expect(described_class.valid?("caries", part: "crown", tooth: 11, face: "M")).to be(true)
    expect(described_class.reason("caries", part: "crown", tooth: 11, face: "M")).to be_nil
  end

  it "decíduo nunca recebe coroa nem prótese fixa/removível" do
    expect(described_class.reason("crown", part: "crown", tooth: 54)).to eq(:situation_not_allowed_for_tooth)
    expect(described_class.reason("crown_unit_prosthesis", part: "crown", tooth: 61)).to eq(:situation_not_allowed_for_tooth)
    expect(described_class.reason("crown", part: "crown", tooth: 14)).to be_nil
  end

  it "lesão de furca só nos pré-molares e molares (14–18, 24–28, 34–38, 44–48)" do
    expect(described_class.reason("furcation_lesion", part: "root", tooth: 11)).to eq(:situation_not_allowed_for_tooth)
    expect(described_class.valid?("furcation_lesion", part: "root", tooth: 16)).to be(true)
    expect(described_class.valid?("furcation_lesion", part: "root", tooth: 55)).to be(false)
  end

  it "situação que não é de face, na face → invalid_situation; código, parte ou face desconhecidos → invalid_situation" do
    expect(described_class.reason("extracted", part: "crown", tooth: 11, face: "M")).to eq(:invalid_situation)
    expect(described_class.reason("caries", part: "root", tooth: 11, face: "M")).to eq(:invalid_situation)
    expect(described_class.reason("caries", part: "crown", tooth: 11, face: "X")).to eq(:invalid_situation)
    expect(described_class.reason("implant", part: "crown", tooth: 11)).to eq(:invalid_situation)
    expect(described_class.reason("xyz", part: "crown", tooth: 11)).to eq(:invalid_situation)
    expect(described_class.reason("caries", part: "gum", tooth: 11)).to eq(:invalid_situation)
    expect(described_class.reason(nil, part: "crown", tooth: 11)).to eq(:invalid_situation)
  end

  it "dente inexistente → situation_not_allowed_for_tooth; arcada dispensa o dente" do
    expect(described_class.reason("caries", part: "crown", tooth: 19)).to eq(:situation_not_allowed_for_tooth)
    expect(described_class.reason("complete_denture", part: "arch", tooth: nil)).to be_nil
    expect(described_class.reason("complete_denture", part: "arch", tooth: 51)).to eq(:situation_not_allowed_for_tooth)
    expect(described_class.reason("complete_denture", part: "arch", tooth: nil, face: "M")).to eq(:invalid_situation)
  end
end
