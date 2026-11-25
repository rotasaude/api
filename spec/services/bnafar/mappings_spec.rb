require "rails_helper"

# Módulo 27b (Task 1): DM01, DM12, DM13/DM14, unidades e limites do SI-BNAFAR.
RSpec.describe "Mapeamentos do BNAFAR", type: :model do
  # Oráculo independente (R29): os 21 códigos da DM12 do manual v1.25 §15.
  dm12_codes = %w[S-AE S-AEA S-AJ S-AS S-CA S-D S-DD S-DEP S-DEPART S-DF S-E S-EE S-EES S-ES S-PA S-PE S-SAC S-T
                  S-TR S-TROCA S-VV]

  let(:movement) { Struct.new(:kind, :quantity) }
  let(:adjustment) { Struct.new(:loss_code) }
  let(:external) { Struct.new(:exit_type) }

  describe "DM01" do
    it "os cinco tipos de local mapeados" do
      expect(%w[central cold_chain_central unit vaccine_room vector_control].map { |k| Bnafar::LocationTypes.for(Struct.new(:kind).new(k)) })
        .to eq(%w[A A F F F])
      expect(Bnafar::Domains.dm01.keys).to eq(%w[A R F])
    end
  end

  describe "DM12" do
    it "cada NEGATIVE_KINDS tem tipo ou :ignored" do
      Pharmacy::Catalog::NEGATIVE_KINDS.each do |kind|
        result = Bnafar::ExitTypes.for(movement.new(kind, -1))
        expect(result).to(satisfy("tipo, :ignored ou :reversal para #{kind}") { |r| r == :ignored || r.is_a?(String) }, kind)
      end
    end

    it "os três *_reversal são :reversal e opening_reversal é :ignored" do
      %w[immunization_reversal vector_application_reversal animal_vaccination_reversal].each do |kind|
        expect(Bnafar::ExitTypes.for(movement.new(kind, 1))).to eq(:reversal)
      end
      expect(Bnafar::ExitTypes.for(movement.new("opening_reversal", -3))).to eq(:ignored)
      expect(Bnafar::ExitTypes.for(movement.new("dispensing", -3))).to eq(:ignored)
    end

    it "loss com loss_code expired -> S-VV; sem -> S-PE; expiry -> S-VV; transferência -> S-T" do
      expect(Bnafar::ExitTypes.for(movement.new("loss", -1), adjustment: adjustment.new("expired"))).to eq("S-VV")
      expect(Bnafar::ExitTypes.for(movement.new("loss", -1), adjustment: adjustment.new("breakage"))).to eq("S-PE")
      expect(Bnafar::ExitTypes.for(movement.new("loss", -1))).to eq("S-PE")
      expect(Bnafar::ExitTypes.for(movement.new("expiry", -1))).to eq("S-VV")
      expect(Bnafar::ExitTypes.for(movement.new("transfer_out", -1))).to eq("S-T")
    end

    it "adjustment +5 -> :not_exit e -5 -> S-AE" do
      expect(Bnafar::ExitTypes.for(movement.new("adjustment", 5))).to eq(:not_exit)
      expect(Bnafar::ExitTypes.for(movement.new("adjustment", -5))).to eq("S-AE")
    end

    it "movimento positivo é :not_exit e negativo sem mapa é nil" do
      expect(Bnafar::ExitTypes.for(movement.new("receipt", 5))).to eq(:not_exit)
      expect(Bnafar::ExitTypes.for(movement.new("mystery_kind", -1))).to be_nil
    end

    it "uso direto -> S-CA (e nunca S-PA)" do
      %w[administration vial_opening immunization vector_application animal_vaccination collar_placement].each do |kind|
        expect(Bnafar::ExitTypes.for(movement.new(kind, -1))).to eq("S-CA")
      end
      expect(Bnafar::Domains.mappings.fetch("exit_types").values).not_to include("S-PA")
    end

    it "external_exit -> o exit_type informado" do
      expect(Bnafar::ExitTypes.for(movement.new("external_exit", -2), external_exit: external.new("S-DF"))).to eq("S-DF")
      expect(Bnafar::ExitTypes.for(movement.new("external_exit", -2))).to be_nil
    end

    it "nenhum código fora dos 21 da DM12" do
      expect(Bnafar::Domains.dm12.keys).to match_array(dm12_codes)
      expect(dm12_codes.size).to eq(21)
      mapped = Bnafar::Domains.mappings.fetch("exit_types").values + Bnafar::Domains.mappings.fetch("loss_code_exit_types").values
      expect(mapped - dm12_codes).to be_empty
      expect(Bnafar::Catalog::EXTERNAL_EXIT_TYPES - dm12_codes).to be_empty
      expect(Bnafar::Domains.dm12.values).to all(be_a(String))
    end
  end

  describe "DM14" do
    let(:codes) { Bnafar::Domains.programs.map { |p| p["code"] } }

    it "INSULDEP I, S/DOR, URG/EMERG e SM CVD-19 preservam espaço e barra" do
      expect(codes).to include("INSULDEP I", "S/DOR", "URG/EMERG", "SM CVD-19", "S.P.IDOSA")
      expect(codes.uniq).to eq(codes)
    end

    it "toda sigla tem product_type da DM13, label e review" do
      expect(Bnafar::Domains.programs).to all(satisfy { |p| Bnafar::Domains.dm13.key?(p["product_type"]) && p["label"].present? && p["review"] == true })
    end

    it "a amostra do Valor 5" do
      sample = { "B" => %w[AFB AF HIPERTEN DIABETES], "E" => %w[ESP ALZHE GLAUC],
                 "S" => %w[TB HANS IMUN ZOO END DENGUE LEISH], "O" => %w[JUD HOSP UPA] }
      sample.each { |type, list| list.each { |code| expect(Bnafar::ProductTypes.for(code)).to eq(type), code } }
      expect(Bnafar::ProductTypes.for("INEXISTENTE")).to be_nil
    end

    it "os domínios vêm congelados" do
      expect([Bnafar::Domains.dm01, Bnafar::Domains.dm12, Bnafar::Domains.dm13, Bnafar::Domains.programs]).to all(be_frozen)
      expect(Bnafar::Domains.programs.first).to be_frozen
    end
  end

  describe "Units" do
    let(:lot) { Struct.new(:item_kind, :immunobiological_code) }
    let(:ten_dose_code) { Vaccination::Immunobiologicals.all.find { |p| p.doses_per_vial == 10 }.code }

    it "vacina de 10 doses por frasco: 30 -> 3 e 25 -> nil" do
      vaccine = lot.new("immunobiological", ten_dose_code)
      expect(Bnafar::Units.factor(vaccine)).to eq(10)
      expect(Bnafar::Units.to_bnafar(vaccine, 30)).to eq(3)
      expect(Bnafar::Units.to_bnafar(vaccine, 25)).to be_nil
      expect(Bnafar::Units.from_bnafar(vaccine, 3)).to eq(30)
    end

    it "medicamento 12.00 -> 12 e 12.50 -> nil" do
      drug = lot.new("medication", nil)
      expect(Bnafar::Units.to_bnafar(drug, BigDecimal("12.00"))).to eq(12)
      expect(Bnafar::Units.to_bnafar(drug, BigDecimal("12.50"))).to be_nil
    end

    it "vetorial 500.00 -> 500" do
      expect(Bnafar::Units.to_bnafar(lot.new("vector_control", nil), BigDecimal("500.00"))).to eq(500)
    end

    it "fator de um produto com doses_per_vial" do
      expect(Bnafar::Units.factor(Struct.new(:doses_per_vial).new(5))).to eq(5)
    end
  end

  describe "Limits" do
    it "ITEMS_PER_RECORD == 20 e RECORDS_PER_BATCH == 1000" do
      expect(Bnafar::Limits::ITEMS_PER_RECORD).to eq(20)
      expect(Bnafar::Limits::RECORDS_PER_BATCH).to eq(1000)
    end
  end
end
