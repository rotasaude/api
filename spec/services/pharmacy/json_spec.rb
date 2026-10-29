require "rails_helper"

# Módulo 27a (ADR 0045; contrato §2 e H1): as formas <item>, <lot> e <location>.
# `item.unit` é a unidade da CONCENTRAÇÃO; `dispensing_unit` é a de dispensação
# (a gravada no lote, ou a da regra quando não há lote).
RSpec.describe Pharmacy::Json do
  before { pharmacy_city! }
  let(:unit) { unit_location! }

  describe ".item" do
    it "unit = concentração, dispensing_unit à parte, catmat_code inteiro, controlado com a lista" do
      expect(described_class.item(losartana, dispensing_unit: "comprimido")).to eq(
        catalog_item_id: losartana.id, catmat_code: 268_856, name: losartana.label, unit: "mg", dispensing_unit: "comprimido",
        controlled: false, controlled_list: nil
      )
      expect(described_class.item(diazepam, dispensing_unit: "comprimido")).to include(controlled: true, controlled_list: "B1")
      expect(described_class.item(losartana, dispensing_unit: "comprimido")[:catmat_code]).to be_an(Integer)
    end
  end

  describe ".lot" do
    it "leva a unidade de dispensação gravada no lote e NÃO sobrescreve item.unit" do
      lot = stocked_lot!(unit, item: losartana, quantity: "10", lot_number: "LOTE-1")
      json = described_class.lot(lot, catalog: { losartana.id => losartana })
      expect(json).to eq(id: lot.id, lot_number: "LOTE-1", expires_on: lot.expires_on.iso8601, manufacturer: nil,
                         item: described_class.item(losartana, dispensing_unit: "comprimido"))
      expect(json.dig(:item, :unit)).to eq("mg")
      expect(json.dig(:item, :dispensing_unit)).to eq(lot.dispensing_unit)
    end

    it "a unidade do lote vale mesmo quando a regra do YAML hoje daria outra" do
      lot = stocked_lot!(unit, item: losartana, quantity: "10", lot_number: "LOTE-2")
      expect(Pharmacy::DispensingUnit.for(losartana)).to eq("unidade")
      expect(described_class.lot(lot, catalog: { losartana.id => losartana }).dig(:item, :dispensing_unit)).to eq("comprimido")
    end
  end

  describe ".location" do
    it "unidade: id, nome, tipo, a unidade de saúde e ativo" do
      expect(described_class.location(unit)).to eq(id: unit.id, name: unit.name, kind: "unit",
                                                   health_unit: { id: unit.health_unit.id, name: unit.health_unit.name }, active: true)
    end

    it "central: health_unit nulo" do
      central = central_location!
      expect(described_class.location(central)).to eq(id: central.id, name: central.name, kind: "central", health_unit: nil, active: true)
    end
  end
end
