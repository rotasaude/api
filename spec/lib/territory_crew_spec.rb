require "rails_helper"
require Rails.root.join("lib/territory_crew")

RSpec.describe TerritoryCrew do
  let(:dir) { Pathname(Dir.mktmpdir) }
  after { FileUtils.remove_entry(dir) }

  before do
    create_default_protocol!
    ConsentTerm.create!(version: "1", body: "Termo de teste", published_at: Time.current)
    [ [ "UBS Jardim das Flores", "ubs" ], [ "UBS Vila Esperança", "ubs" ], [ "UPA 24h Centro", "upa" ] ]
      .each { |name, kind| create_unit(name, kind: kind) }
    path = dir.join("curitiba.yml")
    path.write(<<~YAML)
      neighborhoods:
        - name: Santa Felicidade
          key: santa-felicidade
          units: ["UBS Jardim das Flores"]
        - name: Boqueirão
          key: boqueirao
          units: ["UBS Vila Esperança"]
        - name: Centro
          key: centro
          units: ["UPA 24h Centro"]
        - name: Batel
          key: batel
    YAML
    Territory::Seed.call(path: path)
  end

  def seed = described_class.seed_current_city(slug: "curitiba", ddd: "41")

  it "dá endereço de CEP real às unidades e cria cidadãos com bairros variados, alguns sem" do
    result = seed

    expect(result).to eq(units_with_address: 3, citizens: 15, new_triages: 15)
    expect(HealthUnit.find_by!(name: "UBS Jardim das Flores")).to have_attributes(
      address_street: "Avenida Manoel Ribas", address_number: "5000", address_zip: "82400000",
      neighborhood: Neighborhood.named("Santa Felicidade").sole
    )
    by_neighborhood = Triage.where(status: "completed").group(:neighborhood_id).count
                            .transform_keys { |id| id && Neighborhood.find(id).name }
    expect(by_neighborhood).to eq("Santa Felicidade" => 6, "Boqueirão" => 3, "Centro" => 1, "Batel" => 2, nil => 3)
    expect(Citizen.all.map(&:cpf)).to all(satisfy { |cpf| CitizenIdentity::Cpf.normalize(cpf) == cpf })
    expect(Triage.distinct.pluck(:tier)).to contain_exactly("alta", "baixa")
  end

  it "é idempotente e não sobrescreve endereço editado" do
    seed
    HealthUnit.find_by!(name: "UPA 24h Centro").update!(address_street: "Rua Editada")
    counts = -> { [ Citizen.count, Conversation.count, Triage.count, NeighborhoodCoverage.count ] }
    before = counts.call

    expect(seed[:new_triages]).to eq(0)
    expect(counts.call).to eq(before)
    expect(HealthUnit.find_by!(name: "UPA 24h Centro").address_street).to eq("Rua Editada")
  end
end
