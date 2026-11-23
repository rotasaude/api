require "rails_helper"
require Rails.root.join("db/city_migrate/20261123900001_add_zoonoses_foundation.rb").to_s

# Módulo 35b (ADR 0054; plano, Valor fixado 2; contrato §1 e §16, Q26):
# catálogo, eventos de domínio, filtro de log e cifra por cidade.
RSpec.describe Zoonoses::Catalog, type: :model do
  let(:contract) do
    %w[
      animal.registered animal.changed rabies_campaign.changed rabies_vaccination.recorded rabies_vaccination.cancelled
      zoonoses_demand.opened zoonoses_demand.changed bite_observation.opened bite_observation.closed
      bite_observation.contact_viewed leish_survey.changed leish_test.recorded leish_dog_outcome.recorded collar.placed
      collar.removed shelter_stay.opened shelter_stay.closed neutering.recorded euthanasia.recorded zoonoses_parameters.changed
    ]
  end

  it "DOMAIN_EVENTS = os 20 do §16, na ordem, mais animal.viewed e zoonoses_demand.viewed, todos declarados sem consumidor" do
    expect(described_class::DOMAIN_EVENTS).to eq(contract + %w[animal.viewed zoonoses_demand.viewed])
    expect(described_class::DOMAIN_EVENTS.size).to eq(22)
    expect(DomainEvents.registry.keys).to include(*described_class::DOMAIN_EVENTS)
    expect(described_class::DOMAIN_EVENTS.flat_map { |name| DomainEvents.registry[name] }).to be_empty
  end

  it "o filtro de log mascara microchip, place_address, animal_address, animal_tutor_name, animal_tutor_phone, adverse_note, inspection_note, reason_note" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    keys = %w[microchip place_address animal_address animal_tutor_name animal_tutor_phone adverse_note inspection_note reason_note]
    filtered = filter.filter(keys.to_h { |key| [ key, "segredo" ] })
    expect(filtered.values.uniq).to eq([ "[FILTERED]" ])
  end

  it "CITY_KEYED_TARGETS cobre os encrypts novos (guarda exaustiva)" do
    registered = CityEncryption::CITY_KEYED_TARGETS.map { |model, attribute| [ model, attribute.to_sym ] }
    expect(registered).to include([ Animal, :microchip ], [ OmbudsmanManifestation, :place_address ])
    declared = [ Animal, ZoonosesParameterVersion, OmbudsmanManifestation, OmbudsmanForwarding, OmbudsmanSubject ]
               .flat_map { |model| model.encrypted_attributes.to_a.map { |attribute| [ model, attribute.to_sym ] } }
    expect(declared - registered).to eq([])
    expect(Animal.encrypted_attributes.to_a).to eq([ :microchip ])
    expect(Animal.type_for_attribute(:microchip).deterministic?).to be(true)
  end

  it "o papel é o de Membership, privilegiado; o CBO da veterinária está no catálogo com CRMV" do
    expect(Membership::ROLES).to include(described_class::ROLE)
    expect(Membership::PRIVILEGED_ROLES).to include(described_class::ROLE)
    expect(AddZoonosesFoundation::ROLES).to include(described_class::ROLE)
    cbo = Professionals::Cbo.all.find { |entry| entry.code == described_class::VETERINARIAN_CBO }
    expect([ cbo&.title, cbo&.council ]).to eq([ "Médico veterinário", "CRMV" ])
    expect(Professional::COUNCILS).to include("CRMV")
    expect(described_class::FIELD_CBOS).to eq([ TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO, TerritoryRegistry::Catalog::ACS_CBO ])
  end

  it "os valores fixados do plano" do
    expect(described_class::SUBTYPES)
      .to eq(%w[scorpion bat rodent tick aggressive_animal neurological_animal sporotrichosis other])
    expect(described_class::LABEL).to match("LV-2026-0A1B2C-0001")
    expect(described_class::LABEL).to match("LV-2026-AVUL-0001")
    expect(described_class::LABEL).not_to match("LV-2026-0a1b2c-0001")
    expect(described_class::MICROCHIP).to match("985112345678901")
    expect(described_class::MICROCHIP).not_to match("98511234567890")
    expect(described_class::REPORTS).to eq(%w[rabies_weekly rabies_modalities demands observations leish shelter])
    expect(described_class::PRODUCT_USES).to eq(%w[rabies_vaccine collar])
  end
end
