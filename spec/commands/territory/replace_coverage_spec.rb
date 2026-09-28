require "rails_helper"

RSpec.describe Territory::ReplaceCoverage do
  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:centro) { Neighborhood.create!(name: "Centro", source: "manual") }
  let(:ubs) { create_unit("UBS Centro") }
  let(:upa) { create_unit("UPA Norte", kind: "upa") }
  let(:ubs_sul) { create_unit("UBS Sul") }

  def payloads = DomainEvent.where(name: "neighborhood.coverage_changed").map(&:payload)

  it "substitui o conjunto e publica adicionados e removidos, só ids" do
    described_class.call(neighborhood: centro, health_unit_ids: [ ubs.id, upa.id ], by: admin)
    result = described_class.call(neighborhood: centro, health_unit_ids: [ upa.id, ubs_sul.id ], by: admin)

    expect(result).to be_ok
    expect(result.payload).to include(added: [ ubs_sul.id ], removed: [ ubs.id ])
    expect(centro.coverages.pluck(:health_unit_id)).to contain_exactly(upa.id, ubs_sul.id)
    expect(payloads).to include(
      "neighborhood_id" => centro.id, "added_unit_ids" => [ ubs_sul.id ], "removed_unit_ids" => [ ubs.id ],
      "by_user_id" => admin.id
    )
  end

  it "mesmo conjunto (em outra ordem, com repetição): ok, sem segundo evento" do
    described_class.call(neighborhood: centro, health_unit_ids: [ ubs.id, upa.id ], by: admin)
    described_class.call(neighborhood: centro, health_unit_ids: [ upa.id, ubs.id, upa.id ], by: admin)
    expect(payloads.size).to eq(1)
  end

  it "lista vazia remove tudo" do
    described_class.call(neighborhood: centro, health_unit_ids: [ ubs.id ], by: admin)
    expect(described_class.call(neighborhood: centro, health_unit_ids: [], by: admin)).to be_ok
    expect(centro.coverages).to be_empty
  end

  it "unidade inativa, inexistente ou id que não é UUID: inactive_unit e nada muda" do
    described_class.call(neighborhood: centro, health_unit_ids: [ ubs.id ], by: admin)
    inativa = create_unit("UBS Fechada", active: false)
    [ [ inativa.id ], [ SecureRandom.uuid ], [ "nao-e-uuid" ], [ ubs.id, inativa.id ] ].each do |ids|
      expect(described_class.call(neighborhood: centro, health_unit_ids: ids, by: admin).reason)
        .to eq(:inactive_unit), ids.inspect
    end
    expect(centro.coverages.pluck(:health_unit_id)).to eq([ ubs.id ])
  end

  it "id em caixa alta de unidade já coberta: normaliza, não remove+readiciona nem publica evento" do
    described_class.call(neighborhood: centro, health_unit_ids: [ ubs.id, upa.id ], by: admin)
    result = described_class.call(neighborhood: centro, health_unit_ids: [ ubs.id.upcase, upa.id ], by: admin)

    expect(result).to be_ok
    expect(result.payload).to include(added: [], removed: [])
    expect(centro.coverages.pluck(:health_unit_id)).to contain_exactly(ubs.id, upa.id)
    expect(payloads.size).to eq(1)
  end

  it "bairro inativo: inactive_neighborhood" do
    centro.update!(active: false)
    expect(described_class.call(neighborhood: centro, health_unit_ids: [ ubs.id ], by: admin).reason)
      .to eq(:inactive_neighborhood)
    expect(centro.coverages).to be_empty
  end
end
