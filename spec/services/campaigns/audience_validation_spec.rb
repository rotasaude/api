require "rails_helper"

# Achado do plano do dashboard: bairro ou unidade desativados depois de salvo o
# rascunho — prévia, criar, editar, enviar e agendar recusam com o caminho do item.
RSpec.describe Campaigns::AudienceValidation do
  let!(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  let!(:ahu) { Neighborhood.create!(name: "Ahu", source: "seed", active: false) }

  def geo(value) = { "version" => 1, "geo" => value, "clinical" => { "all" => [] } }

  it "bairros ativos passam; inativo ou inexistente é recusado no item" do
    expect(described_class.errors(geo("scope" => "neighborhoods", "neighborhood_ids" => [ centro.id.upcase ]))).to eq([])
    expect(described_class.errors(geo("scope" => "neighborhoods", "neighborhood_ids" => [ centro.id, ahu.id, SecureRandom.uuid ])))
      .to eq([ { path: "/geo/neighborhood_ids/1", message: "inactive_or_unknown" },
               { path: "/geo/neighborhood_ids/2", message: "inactive_or_unknown" } ])
  end

  it "unidade do recorte precisa estar ativa" do
    active = create_unit("UBS Centro")
    inactive = create_unit("UBS Antiga", active: false)
    expect(described_class.errors(geo("scope" => "unit", "health_unit_id" => active.id))).to eq([])
    [ inactive.id, SecureRandom.uuid ].each do |id|
      expect(described_class.errors(geo("scope" => "unit", "health_unit_id" => id)))
        .to eq([ { path: "/geo/health_unit_id", message: "inactive_or_unknown" } ])
    end
  end

  it "erro de formato vem antes e não consulta o banco" do
    expect(described_class.errors(geo("scope" => "neighborhoods", "neighborhood_ids" => "Centro")))
      .to eq([ { path: "/geo/neighborhood_ids", message: "not_a_list" } ])
  end
end
