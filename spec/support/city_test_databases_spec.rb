require "rails_helper"

RSpec.describe "City test database harness" do
  it "runs every example inside the default test city's connection" do
    expect(CityRecord.connection_db_config.database).to eq("rota_saude_test_city_a")
  end

  # Two symmetric, self-contained examples instead of "one writes, the next
  # asserts empty": that shape only proves rollback if the second one
  # happens to run after the first, which depends on execution order (RSpec
  # defaults to :defined here, but nothing pins that — see spec/spec_helper.rb,
  # where `config.order = :random` sits inert inside a commented-out
  # =begin/=end block). Each example below asserts its OWN precondition
  # (empty table) before writing, so whichever of the two runs second is the
  # one that would expose a rollback failure — regardless of which one that
  # is, and without relying on a specific run order.
  it "rolls back writes between examples (writer A)" do
    expect(CityHarnessProbe.count).to eq(0)
    CityHarnessProbe.create!(label: "efêmero-a")
    expect(CityHarnessProbe.count).to eq(1)
  end

  it "rolls back writes between examples (writer B)" do
    expect(CityHarnessProbe.count).to eq(0)
    CityHarnessProbe.create!(label: "efêmero-b")
    expect(CityHarnessProbe.count).to eq(1)
  end

  # Each City with its own slug registers two pools (CityRecord and
  # SolidQueue::Record) that hold a connection for the rest of the process.
  # Without forgetting them after each example, the full suite piled up ~95
  # pools and exhausted Postgres max_connections (100) near the end.
  it "forgets every city shard except the two test cities" do
    city = create(:city, database_url: city_database_url("rota_saude_test_city_b"))
    CityConnection.ensure_pool(city) # registers without checking out, so nothing is pinned

    expect(CityTestDatabases.transient_city_shards).to include(city.shard)
    expect(CityTestDatabases.transient_city_shards).not_to include(TEST_CITY_A.shard, TEST_CITY_B.shard)

    CityTestDatabases.forget_transient_city_shards!

    expect(CityConnection.registered?(city.shard)).to be(false)
    expect(CityConnection.registered?(TEST_CITY_A.shard)).to be(true)
  end

  it "can switch to the second city with within_city" do
    within_city(TEST_CITY_B) do
      expect(CityRecord.connection_db_config.database).to eq("rota_saude_test_city_b")
    end
    expect(CityRecord.connection_db_config.database).to eq("rota_saude_test_city_a")
  end
end
