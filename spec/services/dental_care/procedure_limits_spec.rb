require "rails_helper"

# Módulo 28 (ADR 0046; Desvio 6; contrato §16 O5, O21): local e quantidade
# máxima por SIGTAP da lista do dicionário FAO; fora da lista, só `mouth` e 1,
# salvo os códigos da tabela SIGTAP → situação, que aceitam também o local do
# efeito (sempre 1).
RSpec.describe DentalCare::ProcedureLimits do
  it "entrada da lista: dente 32, sextante 6, arcada 2" do
    expect(described_class.entry("0307010031")).to eq(local: "tooth", max: 32)
    expect(described_class.entry("0307030059")).to eq(local: "sextant", max: 6)
    expect(described_class.entry("0701070129")).to eq(local: "arch", max: 2)
    expect(described_class.entry("0101020074")).to be_nil
  end

  it "max: o da lista; fora dela, 1" do
    expect(described_class.max("0307010031")).to eq(32)
    expect(described_class.max("0101020074")).to eq(1)
  end

  it "location_ok?: Dente → tooth/face; Sextante → sextant; Arcada → arch; fora da lista → mouth" do
    expect(described_class.location_ok?("0307010031", "tooth")).to be(true)
    expect(described_class.location_ok?("0307010031", "face")).to be(true)
    expect(described_class.location_ok?("0307010031", "mouth")).to be(false)
    expect(described_class.location_ok?("0307030059", "sextant")).to be(true)
    expect(described_class.location_ok?("0307030059", "tooth")).to be(false)
    expect(described_class.location_ok?("0701070129", "arch")).to be(true)
    expect(described_class.location_ok?("0701070129", "tooth")).to be(false)
    expect(described_class.location_ok?("0101020074", "mouth")).to be(true)
    expect(described_class.location_ok?("0101020074", "tooth")).to be(false)
    expect(described_class.locations("0307010031")).to eq(%w[tooth face])
    expect(described_class.locations("0101020074")).to eq(%w[mouth])
  end

  it "O21: código da tabela SIGTAP → situação fora da lista aceita mouth e o local do efeito, com máximo 1" do
    allow(DentalCare::SigtapSituations).to receive(:locations).and_call_original
    allow(DentalCare::SigtapSituations).to receive(:locations).with("0101020999").and_return(%w[tooth face])
    expect(described_class.entry("0101020999")).to be_nil
    expect(described_class.locations("0101020999")).to eq(%w[mouth tooth face])
    expect(described_class.location_ok?("0101020999", "face")).to be(true)
    expect(described_class.location_ok?("0101020999", "sextant")).to be(false)
    expect(described_class.max("0101020999")).to eq(1)
  end
end
