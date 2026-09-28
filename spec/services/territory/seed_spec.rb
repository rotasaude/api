require "rails_helper"

RSpec.describe Territory::Seed do
  let(:dir) { Pathname(Dir.mktmpdir) }
  after { FileUtils.remove_entry(dir) }

  def run(yaml)
    path = dir.join("cidade.yml")
    path.write(yaml)
    described_class.call(path: path)
  end

  let!(:ubs) { create_unit("UBS Santa Felicidade") }
  let!(:fechada) { create_unit("UBS Fechada", active: false) }

  let(:yaml) do
    <<~YAML
      neighborhoods:
        - name: Santa Felicidade
          key: santa-felicidade
          units: ["ubs santa felicidade", "UBS Fechada", "UBS Inexistente"]
        - name: Batel
          key: batel
          units: []
        - name: Ahu
          key: ahu
    YAML
  end

  it "cria os bairros com source seed, a chave e a cobertura das unidades ativas achadas pelo nome" do
    report = run(yaml)

    expect([ report.created, report.existing ]).to eq([ 3, 0 ])
    expect(report.warnings).to contain_exactly(match(/UBS Fechada/), match(/UBS Inexistente/))
    santa = Neighborhood.named("Santa Felicidade").sole
    expect(santa).to have_attributes(source: "seed", active: true, seed_key: "santa-felicidade")
    expect(santa.health_units).to eq([ ubs ])
    expect(Neighborhood.named("Ahu").sole.coverages).to be_empty
  end

  it "rodar duas vezes não muda nada" do
    run(yaml)
    snapshot = -> { [ Neighborhood.order(:name).pluck(:name, :active, :source, :seed_key), NeighborhoodCoverage.count, DomainEvent.count ] }
    before = snapshot.call
    report = run(yaml)
    expect(snapshot.call).to eq(before)
    expect([ report.created, report.existing ]).to eq([ 0, 3 ])
  end

  it "não desfaz edição: renomeado não é recriado nem renomeado; desativado e cobertura editada ficam" do
    run(yaml)
    santa = Neighborhood.find_by!(seed_key: "santa-felicidade")
    Territory::RenameNeighborhood.call(neighborhood: santa, name: "Santa Felicidade Velha", by: nil)
    Territory::ReplaceCoverage.call(neighborhood: santa, health_unit_ids: [], by: nil)
    batel = Neighborhood.find_by!(seed_key: "batel")
    Territory::SetNeighborhoodActive.call(neighborhood: batel, active: false, by: nil)

    report = run(yaml)
    expect([ report.created, report.existing ]).to eq([ 0, 3 ])
    expect(Neighborhood.count).to eq(3)
    expect(santa.reload).to have_attributes(name: "Santa Felicidade Velha", seed_key: "santa-felicidade")
    expect(santa.coverages).to be_empty
    expect(batel.reload.active).to be(false)
  end

  it "bairro manual com o mesmo nome: aviso, sem duplicado, sem adotar a chave, sem cobertura" do
    manual = Neighborhood.create!(name: "SANTA FELICIDADE", source: "manual")
    report = run(yaml)
    expect(report.created).to eq(2)
    expect(report.warnings).to include(match(/Santa Felicidade.*já existe/))
    expect(Neighborhood.named("Santa Felicidade").count).to eq(1)
    expect(manual.reload.seed_key).to be_nil
    expect(manual.coverages).to be_empty
  end

  it "entrada sem nome ou sem key vira aviso; arquivo sem a chave neighborhoods não cria nada" do
    expect(run("neighborhoods:\n  - key: x\n  - name: Batel\n").warnings)
      .to contain_exactly(match(/sem nome/), match(/sem key/))
    expect(run("outra: 1\n").created).to eq(0)
    expect(Neighborhood.count).to eq(0)
  end
end
