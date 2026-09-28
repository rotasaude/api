require "rails_helper"

# As sementes versionadas (ADR 0023): bairros reais, nomes que o banco aceita,
# e cobertura ligando as unidades da semente de dev (2 a 4 bairros cada).
RSpec.describe "Sementes de bairros (db/seeds/territory)" do
  files = Dir[Rails.root.join("db/seeds/territory/*.yml").to_s].sort

  it "existem para curitiba e maringa" do
    expect(files.map { |f| File.basename(f) }).to eq(%w[curitiba.yml maringa.yml])
  end

  files.each do |path|
    describe File.basename(path) do
      let(:entries) { YAML.safe_load_file(path).fetch("neighborhoods") }
      let(:names) { entries.map { |e| e.fetch("name") } }

      it "nomes são texto, únicos sem diferenciar maiúsculas, sem espaço extra, até 120" do
        expect(names).to all(be_a(String))
        expect(names.map(&:downcase).uniq.size).to eq(names.size)
        expect(names).to all(satisfy { |n| n == n.squish && n.length.between?(1, 120) })
      end

      it "key é slug estável, única" do
        keys = entries.map { |e| e.fetch("key") }
        expect(keys).to all(match(/\A[a-z0-9]+(-[a-z0-9]+)*\z/))
        expect(keys.uniq.size).to eq(keys.size)
      end

      it "units é lista de nomes, e cada unidade cobre de 2 a 4 bairros" do
        units = entries.map { |e| e.fetch("units", []) }
        expect(units).to all(be_an(Array))
        expect(units.flatten.tally.values).to all(be_between(2, 4))
      end
    end
  end

  it "curitiba tem os 75 bairros oficiais" do
    expect(YAML.safe_load_file(files.first).fetch("neighborhoods").size).to eq(75)
  end
end
