require "rails_helper"

# Módulo 35a (ADR 0054; contrato §2, decisão 26): o raio em anéis pelo grafo
# de vizinhos vigentes. Os de partida sempre entram; quarteirão inativo e par
# desfeito não propagam. É a única função de raio do 35a.
RSpec.describe "VectorControl::Rings", type: :model do
  before { vector_city! }

  let(:north) { Neighborhood.create!(name: "Norte #{SecureRandom.hex(3)}", source: "manual") }
  let(:south) { Neighborhood.create!(name: "Sul #{SecureRandom.hex(3)}", source: "manual") }

  def link!(a, b)
    first, second = [ a, b ].sort_by(&:id)
    CityBlockNeighbor.create!(city_block: first, neighbor_block: second)
  end

  # a — b — c (c em outro bairro) — d; e isolado.
  let!(:a) { city_block!(neighborhood: north, number: "1") }
  let!(:b) { city_block!(neighborhood: north, number: "2") }
  let!(:c) { city_block!(neighborhood: south, number: "1") }
  let!(:d) { city_block!(neighborhood: south, number: "2") }
  let!(:e) { city_block!(neighborhood: north, number: "9") }

  before do
    link!(a, b)
    link!(b, c)
    link!(c, d)
  end

  it "rings 1 = os vizinhos diretos mais o de partida" do
    expect(VectorControl::Rings.around([ b.id ], rings: 1)).to contain_exactly(a.id, b.id, c.id)
  end

  it "rings 2 alcança o vizinho do vizinho, cruzando bairro" do
    expect(VectorControl::Rings.around([ a.id ], rings: 2)).to contain_exactly(a.id, b.id, c.id)
    expect(VectorControl::Rings.around([ a.id ], rings: 3)).to contain_exactly(a.id, b.id, c.id, d.id)
  end

  it "par com ended_at e quarteirão inativo não propagam" do
    CityBlockNeighbor.find_by!(city_block_id: [ b.id, c.id ].min, neighbor_block_id: [ b.id, c.id ].max).update!(ended_at: Time.current)
    expect(VectorControl::Rings.around([ a.id ], rings: 3)).to contain_exactly(a.id, b.id)

    link!(b, c)
    b.update!(active: false)
    expect(VectorControl::Rings.around([ a.id ], rings: 3)).to contain_exactly(a.id)
    # O de partida inativo fica no resultado, mas não expande (contrato §2: ignora inativos).
    expect(VectorControl::Rings.around([ b.id ], rings: 2)).to contain_exactly(b.id)
    expect(VectorControl::Rings.around([ b.id, d.id ], rings: 1)).to contain_exactly(b.id, c.id, d.id)
  end

  it "rings 0 = só os de partida" do
    expect(VectorControl::Rings.around([ a.id, e.id ], rings: 0)).to contain_exactly(a.id, e.id)
    expect(VectorControl::Rings.around([], rings: 2)).to eq([])
  end
end
