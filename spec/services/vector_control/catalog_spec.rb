require "rails_helper"
require Rails.root.join("db/city_migrate/20261116900001_add_vector_control_territory.rb").to_s

# Módulo 35a (ADR 0054; plano, Valor fixado 2; contrato §1 e §17): catálogo,
# eventos de domínio e filtro de log.
RSpec.describe VectorControl::Catalog, type: :model do
  let(:contract) do
    %w[
      city_block.changed household_vector_profile.changed vector_stock.shortfall_recorded
      vector_stock.shortfall_reconciled ovitrap.installed ovitrap.collected ovitrap_reading.counted
      vector_task.opened vector_task.closed liraa_survey.drawn liraa_survey.closed
      transmission_block.proposed transmission_block.confirmed transmission_block.dismissed
      transmission_block.closed transmission_block_case.address_viewed vector_sample.result_recorded
      vector_parameters.changed vector_product.changed transmission_block_case.moved
    ]
  end

  it "DOMAIN_EVENTS = os 20 nomes do §17 (o moved da Q26(2) no fim) e todos declarados sem consumidor" do
    expect(described_class::DOMAIN_EVENTS).to eq(contract)
    expect(described_class::DOMAIN_EVENTS.size).to eq(20)
    expect(DomainEvents.registry.keys).to include(*contract)
    expect(contract.flat_map { |name| DomainEvents.registry[name] }).to be_empty
  end

  it "DERIVED_REASONS ⊂ HomeVisits::Catalog::NON_RESIDENTIAL_REASONS" do
    expect(described_class::DERIVED_REASONS - HomeVisits::Catalog::NON_RESIDENTIAL_REASONS).to be_empty
  end

  it "PROPERTY_CLASSES cobre TerritoryRegistry::Catalog::PROPERTY_TYPES sem sobra" do
    types = described_class::PROPERTY_CLASSES.values.flatten
    expect(types).to match_array(TerritoryRegistry::Catalog::PROPERTY_TYPES)
    expect(types.uniq.size).to eq(types.size)
    expect(described_class::PROPERTY_CLASSES["PE"]).to eq([ described_class::PE_PROPERTY ])
  end

  it "os papéis são os de Membership e da migração" do
    expect(Membership::ROLES).to include(*described_class::ROLES)
    expect(described_class::RISK_CLASSES).to eq(AddVectorControlTerritory::RISK_CLASSES)
    expect(described_class::SITUATIONS).to eq(AddVectorControlTerritory::SITUATIONS)
  end

  # Q38: grupo novo em TransmissionBlock::DISEASE_GROUPS sem rótulo falha aqui.
  it "DISEASE_GROUP_LABELS rotula cada código de TransmissionBlock::DISEASE_GROUPS, sem sobra" do
    labels = described_class::DISEASE_GROUP_LABELS
    expect(labels.keys).to eq(TransmissionBlock::DISEASE_GROUPS)
    expect(labels.values).to all(be_a(String).and(be_present))
    expect(labels["arbovirus"]).to eq("Arboviroses (dengue, chikungunya, zika)")
  end

  it "o filtro de log mascara count_note, result_note, closed_note, dismissed_reason, reconciliation_note" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    keys = %w[count_note result_note closed_note dismissed_reason reconciliation_note]
    filtered = filter.filter(keys.to_h { |key| [ key, "segredo" ] })
    expect(filtered.values.uniq).to eq([ "[FILTERED]" ])
  end
end
