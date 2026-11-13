require "rails_helper"

# api#159: o preparo de seed_once roda uma vez, cada exemplo parte do mesmo
# estado (o que um exemplo escreve volta no fim dele) e nada fica no banco
# depois do arquivo. A ordem é fixa só aqui: o último exemplo prova o rollback
# do after(:context) do grupo anterior.
RSpec.describe "seed_once", order: :defined do
  def probe_labels = CityHarnessProbe.order(:label).pluck(:label)

  describe "dentro do grupo" do
    seed_once do
      CityHarnessProbe.create!(label: "semeado")
      Maintainer.create!(email_address: "seed-once@local", password: "s3nha-forte-1", otp_secret: ROTP::Base32.random,
                         otp_enabled_at: Time.current)
      @seeded_at_runs = (@seeded_at_runs || 0) + 1
    end

    it "vê a semente da cidade e a da plataforma, e escreve por cima" do
      expect(probe_labels).to eq([ "semeado" ])
      expect(Maintainer.where(email_address: "seed-once@local").count).to eq(1)
      CityHarnessProbe.create!(label: "do exemplo 1")
      Maintainer.find_by!(email_address: "seed-once@local").destroy!
    end

    it "parte da semente intacta: o que o exemplo anterior fez voltou" do
      expect(probe_labels).to eq([ "semeado" ])
      expect(Maintainer.where(email_address: "seed-once@local").count).to eq(1)
      expect(@seeded_at_runs).to eq(1)
    end
  end

  describe "pool novo no preparo" do
    it "recusa: o que fosse escrito nele seria commitado" do
      pinned = SeedOnce.writing_pools
      fake = instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool, shard: :nova,
                             connection_descriptor: Struct.new(:name).new("Fake"))
      allow(SeedOnce).to receive(:writing_pools).and_return(pinned + [ fake ])

      expect { SeedOnce.refuse_new_pools!(pinned) }.to raise_error(SeedOnce::NewPoolOpened, %r{Fake/nova})
    end

    it "aceita quando os pools são os mesmos" do
      expect { SeedOnce.refuse_new_pools!(SeedOnce.writing_pools) }.not_to raise_error
    end
  end

  # Grupo irmão, e não exemplo do grupo de fora: com order: :defined o RSpec
  # roda os exemplos de um grupo antes dos grupos filhos.
  describe "depois do grupo" do
    it "nada da semente ficou no banco" do
      expect(CityHarnessProbe.count).to eq(0)
      expect(Maintainer.where(email_address: "seed-once@local").count).to eq(0)
    end
  end
end
