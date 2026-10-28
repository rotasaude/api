require "rails_helper"

# Módulo 26a: a pré-checagem de unicidade não fecha a corrida; o índice único
# do banco é a verdade e o rescue mapeia a violação para a mesma recusa.
RSpec.describe "Regulação — corrida de unicidade em prestadores e ofertas" do
  before { regulation_city! }

  let(:admin) { regulation_admin! }

  describe CareRegulation::SaveProvider do
    # A pré-checagem não vê o que outra transação gravou entre a leitura e a escrita.
    before { allow(described_class).to receive(:taken_reason).and_return(nil) }

    it "violação do índice de CNES → cnes_taken, nada gravado a mais" do
      external_provider!(cnes: "3456781")
      result = described_class.call(attrs: { "name" => "Clínica J", "kind" => "contracted", "cnes" => "3456781" }, by: admin)
      expect([ result.failure?, result.reason ]).to eq([ true, :cnes_taken ])
      expect(CareProvider.count).to eq(1)
      expect(DomainEvent.where(name: "care_provider.changed")).to be_empty
    end

    it "violação do índice da unidade → unit_taken" do
      unit = HealthUnit.create!(name: "UBS Corrida", kind: "ubs", cnes: "2384299")
      own_provider!(unit)
      result = described_class.call(attrs: { "name" => "UBS Corrida", "kind" => "own", "health_unit_id" => unit.id }, by: admin)
      expect([ result.failure?, result.reason ]).to eq([ true, :unit_taken ])
      expect(CareProvider.count).to eq(1)
    end

    it "violação do índice de CNES no PATCH → cnes_taken, o CNES antigo fica" do
      external_provider!(cnes: "3456781")
      other = external_provider!(cnes: "3456782")
      result = described_class.call(attrs: { "cnes" => "3456781" }, by: admin, provider: other)
      expect([ result.failure?, result.reason ]).to eq([ true, :cnes_taken ])
      expect(other.reload.cnes).to eq("3456782")
    end
  end

  describe CareRegulation::SaveOffer do
    it "violação do índice único da oferta → duplicate_offer" do
      provider = external_provider!
      offer!(provider: provider, quantity: 5)
      allow(CareOffer).to receive(:exists?).and_return(false)
      attrs = { "provider_id" => provider.id, "target_type" => "specialty", "target_code" => "225120",
                "month" => Time.zone.today.strftime("%Y-%m"), "quantity" => 9 }
      result = described_class.call(attrs: attrs, by: admin)
      expect([ result.failure?, result.reason ]).to eq([ true, :duplicate_offer ])
      expect(CareOffer.count).to eq(1)
      expect(DomainEvent.where(name: "care_offer.changed")).to be_empty
    end
  end
end
