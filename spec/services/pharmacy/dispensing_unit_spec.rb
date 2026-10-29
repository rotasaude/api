require "rails_helper"

# Módulo 27a (ADR 0045, Desvio 1): a unidade de dispensação sai do dosage_form
# do catálogo (a unidade do catálogo é a da concentração, "mg"). A primeira
# regra do YAML cuja palavra está no dosage_form vence; sem casamento, "unidade".
RSpec.describe Pharmacy::DispensingUnit do
  def unit_for(dosage_form) = described_class.for(MedicationCatalogItem.new(dosage_form: dosage_form))

  it "casa a palavra do dosage_form, sem acento e sem diferenciar caixa" do
    expect(unit_for("comprimido revestido")).to eq("comprimido")
    expect(unit_for("COMPRIMIDO")).to eq("comprimido")
    expect(unit_for("drágea")).to eq("comprimido")
    expect(unit_for("cápsula")).to eq("cápsula")
    expect(unit_for("CAPSULA GELATINOSA DURA")).to eq("cápsula")
    expect(unit_for("creme vaginal")).to eq("bisnaga")
    expect(unit_for("pomada oftálmica")).to eq("bisnaga")
    expect(unit_for("aerosol oral")).to eq("frasco")
    expect(unit_for("solução oral")).to eq("frasco")
    expect(unit_for("SUSPENSÃO")).to eq("frasco")
    expect(unit_for("colírio")).to eq("frasco")
    expect(unit_for("solução injetável")).to eq("frasco")
    expect(unit_for("injetável")).to eq("ampola")
    expect(unit_for("ampola")).to eq("ampola")
    expect(unit_for("sachê")).to eq("envelope")
    expect(unit_for("pó")).to eq("envelope")
  end

  it "a primeira regra do YAML vence quando duas casam" do
    expect(unit_for("comprimido para solução oral")).to eq("comprimido")
    expect(unit_for("cápsula em gel")).to eq("cápsula")
  end

  it "o 'po ' do YAML (com espaço) casa a palavra inteira e não o fim de 'grupo' ou 'tipo'" do
    expect(unit_for("composto oral")).to eq("unidade")
    expect(unit_for("grupo oral")).to eq("unidade")
    expect(unit_for("uso tipo balsâmico")).to eq("unidade")
    expect(unit_for("pó para uso oral")).to eq("envelope")
  end

  it "sem dosage_form, em branco ou sem casamento: unidade" do
    expect(unit_for(nil)).to eq("unidade")
    expect(unit_for("")).to eq("unidade")
    expect(unit_for("supositório retal")).to eq("unidade")
    expect(described_class.for(nil)).to eq("unidade")
  end

  # O recorte de dev do CATMAT: a descrição da LOSARTANA ("DOSAGEM: 50 MG") não
  # traz a forma, então o dosage_form importado é nulo e a regra cai em
  # "unidade"; a forma só vem quando a descrição a nomeia ("DOSAGEM
  # COMPRIMIDO: 500 MG", o PARACETAMOL do recorte).
  it "catálogo importado: a forma vem do dosage_form gravado, nunca da concentração" do
    pharmacy_city!
    paracetamol = catalog_item(267_778)
    expect(paracetamol.dosage_form).to match(/comprimido/i)
    expect(described_class.for(paracetamol)).to eq("comprimido")
    expect(losartana.dosage_form).to be_nil
    expect(described_class.for(losartana)).to eq("unidade")
    expect(described_class.for(paracetamol)).not_to eq(paracetamol.unit)
  end
end
