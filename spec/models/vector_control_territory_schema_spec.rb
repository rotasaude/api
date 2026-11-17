require "rails_helper"
require Rails.root.join("db/city_migrate/20261116900001_add_vector_control_territory.rb").to_s

# Módulo 35a (ADR 0054; contrato §1): o banco do território. Número do
# quarteirão único sem caixa no bairro; par de vizinhos guardado uma vez (a <
# b), único entre os vigentes e só desfeito (A-6); perfil com risco e data
# juntos; cadência única com nulo como valor e PE sem risco (W-10); ciclos sem
# sobreposição; parâmetros só acréscimo; nada se apaga nem se esvazia.
RSpec.describe "Esquema do território do módulo 35a", type: :model do
  before { vector_city! }

  # Escrita crua que o banco recusa: sem savepoint a recusa aborta a transação do exemplo.
  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  let(:neighborhood) { Neighborhood.create!(name: "Bairro #{SecureRandom.hex(3)}", source: "manual") }
  let(:coordinator) { endemic_coordinator! }

  def pair!
    [ city_block!(neighborhood: neighborhood, number: "1"), city_block!(neighborhood: neighborhood, number: "2") ].sort_by(&:id)
  end

  it "AddVectorControlTerritory::HEALTH_UNIT_KINDS == HealthUnit::KINDS; o banco aceita a unidade ambiental; irreversível" do
    expect(AddVectorControlTerritory::HEALTH_UNIT_KINDS).to eq(HealthUnit::KINDS)
    expect(HealthUnit::KINDS.last).to eq("environmental_surveillance")
    expect { HealthUnit.create!(name: "UVZ #{SecureRandom.hex(2)}", kind: "environmental_surveillance") }.not_to raise_error
    expect { AddVectorControlTerritory.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  it "número do quarteirão único sem caixa no bairro" do
    city_block!(neighborhood: neighborhood, number: "12A")
    expect { city_block!(neighborhood: neighborhood, number: "12a") }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_city_blocks_number/)
    other = Neighborhood.create!(name: "Bairro #{SecureRandom.hex(3)}", source: "manual")
    expect { city_block!(neighborhood: other, number: "12a") }.not_to raise_error
    block = city_block!(neighborhood: neighborhood, number: "7")
    refused(/ck_city_blocks_number/) { block.update_columns(number: "7 B") }
    refused(/ck_city_blocks_version/) { block.update_columns(version: 0) }
  end

  it "par de vizinhos guardado uma vez (a < b), desfeito com ended_at e refeito depois (A-6)" do
    a, b = pair!
    refused(/ck_city_block_neighbors_order/) { CityBlockNeighbor.create!(city_block: b, neighbor_block: a) }
    refused(/ck_city_block_neighbors_order/) { CityBlockNeighbor.create!(city_block: a, neighbor_block: a) }
    first = CityBlockNeighbor.create!(city_block: a, neighbor_block: b)
    expect { CityBlockNeighbor.create!(city_block: a, neighbor_block: b) }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_city_block_neighbors_pair/)
    refused(/only ended_at changes/) { first.update_columns(neighbor_block_id: city_block!(neighborhood: neighborhood, number: "3").id) }
    first.update!(ended_at: Time.current)
    refused(/from NULL to a value, once/) { first.update_columns(ended_at: 1.minute.from_now) }
    again = CityBlockNeighbor.create!(city_block: a, neighbor_block: b)
    expect(CityBlockNeighbor.current.where(city_block: a)).to contain_exactly(again)
    refused(/from NULL to a value, once/) { again.update_columns(ended_at: nil) }
  end

  it "vizinho nunca é apagado" do
    a, b = pair!
    neighbor = CityBlockNeighbor.create!(city_block: a, neighbor_block: b)
    refused(/city_block_neighbors: DELETE refused/) { neighbor.delete }
    neighbor.update!(ended_at: Time.current)
    refused(/city_block_neighbors: DELETE refused/) { neighbor.delete }
  end

  it "perfil: risco sem data → CHECK; um por domicílio" do
    household = registry_household!
    block = city_block!(neighborhood: neighborhood, number: "5")
    refused(/ck_household_vector_profiles_risk/) do
      HouseholdVectorProfile.create!(household: household, city_block: block, risk_class: "red")
    end
    refused(/ck_household_vector_profiles_risk/) do
      HouseholdVectorProfile.create!(household: household, city_block: block, risk_assessed_on: Time.zone.today)
    end
    profile = vector_profile!(household, block: block, risk: "red")
    expect(profile.reload).to have_attributes(risk_class: "red", risk_assessed_on: Time.zone.today, version: 1)
    expect { vector_profile!(household, block: nil) }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_household_vector_profiles_household/)
    refused(/ck_household_vector_profiles_risk_class/) { profile.update_columns(risk_class: "blue") }
    refused(/ck_household_vector_profiles_last_situation/) { profile.update_columns(last_situation: "absent") }
  end

  it "cadência (nil, nil, false) e (bairro, nil, false) únicas com nulo como valor" do
    VectorCadence.create!(days: 60)
    expect { VectorCadence.create!(days: 30) }.to raise_error(ActiveRecord::RecordNotUnique, /idx_vector_cadences_key/)
    VectorCadence.create!(neighborhood: neighborhood, days: 45)
    expect { VectorCadence.create!(neighborhood: neighborhood, days: 30) }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_vector_cadences_key/)
    expect { VectorCadence.create!(neighborhood: neighborhood, risk_class: "red", days: 30) }.not_to raise_error
    expect { VectorCadence.create!(strategic_point: true, days: 15) }.not_to raise_error
    refused(/ck_vector_cadences_days/) { VectorCadence.new(risk_class: "green", days: 6).save!(validate: false) }
    refused(/ck_vector_cadences_days/) { VectorCadence.new(risk_class: "green", days: 366).save!(validate: false) }
  end

  it "cadência de PE com risco → CHECK" do
    refused(/ck_vector_cadences_strategic_point/) { VectorCadence.create!(strategic_point: true, risk_class: "red", days: 15) }
  end

  it "ciclos sobrepostos → exclusion" do
    VectorCycle.create!(year: 2026, number: 1, starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 1, 31))
    refused(/excl_vector_cycles_overlap/) do
      VectorCycle.create!(year: 2026, number: 2, starts_on: Date.new(2026, 1, 31), ends_on: Date.new(2026, 2, 28))
    end
    expect { VectorCycle.create!(year: 2026, number: 2, starts_on: Date.new(2026, 2, 1), ends_on: Date.new(2026, 2, 28)) }.not_to raise_error
    expect { VectorCycle.create!(year: 2026, number: 1, starts_on: Date.new(2026, 3, 1), ends_on: Date.new(2026, 3, 31)) }
      .to raise_error(ActiveRecord::RecordNotUnique, /idx_vector_cycles_number/)
    refused(/ck_vector_cycles_number/) do
      VectorCycle.new(year: 2026, number: 13, starts_on: Date.new(2026, 4, 1), ends_on: Date.new(2026, 4, 30)).save!(validate: false)
    end
    refused(/ck_vector_cycles_dates/) do
      VectorCycle.create!(year: 2026, number: 3, starts_on: Date.new(2026, 5, 2), ends_on: Date.new(2026, 5, 1))
    end
  end

  it "DELETE recusado (salvo a cadência) e TRUNCATE recusado; parâmetros só acréscimo" do
    a, b = pair!
    rows = [
      a,
      CityBlockNeighbor.create!(city_block: a, neighbor_block: b),
      vector_profile!(registry_household!, block: a),
      VectorCycle.create!(year: 2026, number: 1, starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 1, 31)),
      VectorParameterVersion.create!(version: 1, values: VectorControl::Parameters.defaults, created_by_user: coordinator),
      VectorControlSetting.current
    ]
    expect(rows.map { |row| row.class.table_name }).to match_array(AddVectorControlTerritory::TABLES - %w[vector_cadences])
    rows.each { |row| refused(/#{row.class.table_name}/) { row.delete } }
    refused(/vector_parameter_versions is append-only/) { rows[4].update_columns(values: { "default_days" => 30 }) }
    cadence = VectorCadence.create!(days: 60)
    expect { cadence.delete }.to change(VectorCadence, :count).by(-1) # o PUT /cadences troca a lista inteira (Task 8)
    AddVectorControlTerritory::TABLES.each do |table|
      refused(/#{table} is append-only/) { CityBlock.connection.execute("TRUNCATE #{table} CASCADE") }
    end
  end
end
