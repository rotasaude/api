require "rails_helper"

RSpec.describe "Comandos de bairro" do
  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }

  def payloads(name) = DomainEvent.where(name: name).map(&:payload)

  describe Territory::CreateNeighborhood do
    it "cria com source manual, normaliza o nome e publica só ids" do
      result = described_class.call(name: "  Santa   Felicidade ", by: admin)
      expect(result).to be_ok
      neighborhood = result.payload[:neighborhood]
      expect(neighborhood).to have_attributes(name: "Santa Felicidade", source: "manual", active: true)
      expect(payloads("neighborhood.created"))
        .to eq([ { "neighborhood_id" => neighborhood.id, "source" => "manual", "by_user_id" => admin.id } ])
    end

    it "semente: source seed, chave da semente e sem autor" do
      neighborhood = described_class.call(name: "Batel", by: nil, source: "seed", seed_key: "batel").payload[:neighborhood]
      expect(neighborhood).to have_attributes(source: "seed", seed_key: "batel")
      expect(payloads("neighborhood.created").sole["by_user_id"]).to be_nil
    end

    it "nome vazio, nulo ou acima de 120: blank_name, nada criado" do
      [ "   ", nil, "x" * 121 ].each do |name|
        expect(described_class.call(name: name, by: admin).reason).to eq(:blank_name), name.inspect
      end
      expect(Neighborhood.count).to eq(0)
    end

    it "nome repetido em outra caixa: name_taken" do
      described_class.call(name: "Batel", by: admin)
      expect(described_class.call(name: "  batel", by: admin).reason).to eq(:name_taken)
      expect(Neighborhood.count).to eq(1)
    end
  end

  describe Territory::RenameNeighborhood do
    let!(:batel) { Territory::CreateNeighborhood.call(name: "Batel", by: admin).payload[:neighborhood] }

    it "renomeia e publica neighborhood.renamed sem o nome" do
      expect(described_class.call(neighborhood: batel, name: "Batel Soho", by: admin)).to be_ok
      expect(batel.reload.name).to eq("Batel Soho")
      expect(payloads("neighborhood.renamed")).to eq([ { "neighborhood_id" => batel.id, "by_user_id" => admin.id } ])
    end

    it "renomear mantém a chave da semente" do
      seeded = Territory::CreateNeighborhood.call(name: "Ahu", by: nil, source: "seed", seed_key: "ahu").payload[:neighborhood]
      described_class.call(neighborhood: seeded, name: "Ahú de Baixo", by: admin)
      expect(seeded.reload.seed_key).to eq("ahu")
    end

    it "só a caixa muda: aceito (não é name_taken)" do
      expect(described_class.call(neighborhood: batel, name: "BATEL", by: admin)).to be_ok
      expect(batel.reload.name).to eq("BATEL")
    end

    it "mesmo nome: ok, sem evento" do
      described_class.call(neighborhood: batel, name: " Batel ", by: admin)
      expect(payloads("neighborhood.renamed")).to be_empty
    end

    it "nome de outro bairro: name_taken e nada muda; vazio: blank_name" do
      Territory::CreateNeighborhood.call(name: "Centro", by: admin)
      expect(described_class.call(neighborhood: batel, name: "centro", by: admin).reason).to eq(:name_taken)
      expect(described_class.call(neighborhood: batel, name: "", by: admin).reason).to eq(:blank_name)
      expect(batel.reload.name).to eq("Batel")
    end
  end

  describe Territory::SetNeighborhoodActive do
    let!(:batel) { Territory::CreateNeighborhood.call(name: "Batel", by: admin).payload[:neighborhood] }

    it "desativa e reativa, com um evento cada; repetir não publica" do
      described_class.call(neighborhood: batel, active: false, by: admin)
      described_class.call(neighborhood: batel, active: false, by: admin)
      expect(batel.reload.active).to be(false)
      described_class.call(neighborhood: batel, active: true, by: admin)
      expect(batel.reload.active).to be(true)
      expect(payloads("neighborhood.deactivated")).to eq([ { "neighborhood_id" => batel.id, "by_user_id" => admin.id } ])
      expect(payloads("neighborhood.activated")).to eq([ { "neighborhood_id" => batel.id, "by_user_id" => admin.id } ])
    end
  end
end
