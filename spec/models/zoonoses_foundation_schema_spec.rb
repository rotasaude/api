require "rails_helper"
require Rails.root.join("db/city_migrate/20261116900001_add_vector_control_territory.rb").to_s
require Rails.root.join("db/city_migrate/20261123900001_add_zoonoses_foundation.rb").to_s

# Módulo 35b (ADR 0054; contrato §1, Q11–Q13; plano, Task 2): o banco da
# fundação. Animal com microchip cifrado determinístico e único entre os não
# nulos, registro único sem caixa, tutor só sem community, situação e
# castração só para a frente, nunca apagado; parâmetros só acréscimo; código
# do assunto único; finalidades de zoonoses sozinhas, em un e carga 1 (Q11);
# encaminhamento do usuário ou do sistema, exatamente um (Q13).
RSpec.describe "Esquema da fundação do módulo 35b", type: :model do
  before { zoonoses_city! }

  # Escrita crua que o banco recusa: sem savepoint a recusa aborta a transação do exemplo.
  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  def accepted(&block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.not_to raise_error
  end

  it "a migração espelha o catálogo e é irreversível" do
    catalog = Zoonoses::Catalog
    expect([ AddZoonosesFoundation::SPECIES, AddZoonosesFoundation::SEXES, AddZoonosesFoundation::SIZES,
             AddZoonosesFoundation::ANIMAL_STATUSES, AddZoonosesFoundation::ZOONOSES_USES ])
      .to eq([ catalog::SPECIES, catalog::SEXES, catalog::SIZES, catalog::ANIMAL_STATUSES, catalog::PRODUCT_USES ])
    expect(AddZoonosesFoundation::PRODUCT_USES).to eq(VectorControl::Catalog::PRODUCT_USES + catalog::PRODUCT_USES)
    expect { AddZoonosesFoundation.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  it "microchip repetido → RecordNotUnique; dois nulos passam" do
    animal!(microchip: "985112345678901")
    expect { animal!(microchip: "985112345678901") }.to raise_error(ActiveRecord::RecordNotUnique, /idx_animals_microchip/)
    expect { 2.times { animal!(microchip: nil) } }.not_to raise_error
    stored = Animal.connection.select_values("SELECT microchip FROM animals WHERE microchip IS NOT NULL")
    expect(stored.join).not_to include("985112345678901")
  end

  it "registro ab12 e AB12 → único sem caixa" do
    animal!(registry_number: "ab12")
    expect { animal!(registry_number: "AB12") }.to raise_error(ActiveRecord::RecordNotUnique, /idx_animals_registry_number/)
    expect { 2.times { animal!(registry_number: nil) } }.not_to raise_error
  end

  it "tutor com community true → CHECK" do
    refused(/ck_animals_tutor/) { animal!(tutor: tutor!, community: true) }
    accepted { animal!(tutor: tutor!, community: false) }
    accepted { animal!(community: true) }
    animal = animal!
    refused(/ck_animals_species/) { animal.update_columns(species: "bird") }
    refused(/ck_animals_sex/) { animal.update_columns(sex: "x") }
    refused(/ck_animals_size/) { animal.update_columns(size: "huge") }
    refused(/ck_animals_status/) { animal.update_columns(status: "lost") }
    refused(/ck_animals_version/) { animal.update_columns(version: 0) }
  end

  it "status deceased → active recusado pelo trigger" do
    animal = animal!
    accepted { animal.update_columns(status: "deceased", status_on: Time.zone.today) }
    refused(/animals: status only leaves active/) { animal.update_columns(status: "active") }
    refused(/animals: status only leaves active/) { animal.update_columns(status: "missing") }
    accepted { animal.update_columns(name: "Rex") }
  end

  it "neutered true → false recusado" do
    animal = animal!
    accepted { animal.update_columns(neutered: true) }
    refused(/animals: neutered never goes back/) { animal.update_columns(neutered: false) }
  end

  it "DELETE recusado; TRUNCATE recusado" do
    animal = animal!
    refused(/animals: DELETE refused/) { animal.delete }
    refused { Animal.connection.execute("TRUNCATE animals CASCADE") }
  end

  it "a re-cifra do microchip passa antes das regras" do
    animal = animal!(microchip: "985112345678902")
    animal.update_columns(status: "deceased")
    accepted do
      Animal.connection.execute("SET LOCAL rota.reencrypting = 'on'")
      Animal.connection.execute(Animal.sanitize_sql([ "UPDATE animals SET microchip = ? WHERE id = ?", "outro-texto", animal.id ]))
    end
  end

  it "parâmetros só acréscimo; versão única" do
    row = ZoonosesParameterVersion.create!(version: 1, values: { "observation_days" => 10 }, created_by_user: zoonoses_coordinator!)
    refused(/append-only|append only/i) { row.update_columns(values: { "observation_days" => 12 }) }
    refused(/append-only|append only/i) { row.delete }
    expect { ZoonosesParameterVersion.create!(version: 1, values: {}, created_by_user: zoonoses_coordinator!) }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_zoonoses_parameter_versions_version/)
    refused(/ck_zoonoses_parameter_versions_values/) do
      ZoonosesParameterVersion.create!(version: 2, values: [ 1 ], created_by_user: zoonoses_coordinator!)
    end
  end

  it "assunto com code repetido → único" do
    OmbudsmanSubject.create!(name: "Zoonoses #{SecureRandom.hex(2)}", code: "zoonoses")
    expect { OmbudsmanSubject.create!(name: "Outro #{SecureRandom.hex(2)}", code: "zoonoses") }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_ombudsman_subjects_code/)
    expect { 2.times { OmbudsmanSubject.create!(name: "Sem código #{SecureRandom.hex(3)}") } }.not_to raise_error
  end

  it "produto rabies_vaccine com unit g → CHECK; com collar e focal → CHECK" do
    refused(/ck_vector_products_zoonoses_uses/) { vector_product!(unit: "g", charge_size: "1.00", uses: %w[rabies_vaccine]) }
    refused(/ck_vector_products_zoonoses_uses/) { vector_product!(unit: "un", charge_size: "2.00", uses: %w[rabies_vaccine]) }
    refused(/ck_vector_products_zoonoses_uses/) { vector_product!(unit: "un", charge_size: "1.00", uses: %w[collar focal]) }
    refused(/ck_vector_products_uses/) { vector_product!(unit: "un", charge_size: "1.00", uses: %w[antiparasitic]) }
    accepted { vector_product!(unit: "un", charge_size: "1.00", uses: %w[rabies_vaccine]) }
    accepted { vector_product!(unit: "un", charge_size: "1.00", uses: %w[collar]) }
    accepted { vector_product!(unit: "g", charge_size: "2.00", uses: %w[focal perifocal]) }
  end

  it "encaminhamento sem usuário e sem created_by_system → CHECK" do
    manifestation = raw_manifestation!(channel: "in_person")
    attrs = { ombudsman_manifestation: manifestation, department: department!, extract: "Extrato do caso para o setor responder.",
              due_on: Date.current + 20, state: "pending" }
    refused(/ck_ombudsman_forwardings_creator/) { OmbudsmanForwarding.create!(**attrs) }
    refused(/ck_ombudsman_forwardings_creator/) do
      OmbudsmanForwarding.create!(**attrs, created_by_user: ombudsman_staff!, created_by_system: true)
    end
    accepted { OmbudsmanForwarding.create!(**attrs, created_by_system: true) }
    accepted { OmbudsmanForwarding.create!(**attrs, created_by_user: ombudsman_staff!) }
    system = OmbudsmanForwarding.find_by!(created_by_system: true)
    refused(/ombudsman_forwardings/) { system.update_columns(created_by_system: false, created_by_user_id: ombudsman_staff!.id) }
  end

  it "manifestação guarda place_address cifrado, imutável" do
    manifestation = raw_manifestation!(channel: "in_person", place_address: "Rua das Flores, 100, fundos")
    expect(manifestation.reload.place_address).to eq("Rua das Flores, 100, fundos")
    raw = OmbudsmanManifestation.connection.select_value(
      OmbudsmanManifestation.sanitize_sql([ "SELECT place_address FROM ombudsman_manifestations WHERE id = ?", manifestation.id ])
    )
    expect(raw).not_to include("Rua das Flores")
    refused(/ombudsman_manifestations: the registration columns never change/) do
      manifestation.update!(place_address: "Outra rua, 200, frente")
    end
  end

  it "inspect, to_s e as_json do animal sem microchip" do
    animal = animal!(microchip: "985112345678903", name: "Bidu")
    [ animal.inspect, animal.to_s, animal.as_json.to_s ].each do |text|
      expect(text).not_to include("985112345678903")
      expect(text).not_to include("Bidu")
      expect(text).to include(animal.id)
    end
  end
end
