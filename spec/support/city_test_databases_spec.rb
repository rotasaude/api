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

  it "can switch to the second city with within_city" do
    within_city(TEST_CITY_B) do
      expect(CityRecord.connection_db_config.database).to eq("rota_saude_test_city_b")
    end
    expect(CityRecord.connection_db_config.database).to eq("rota_saude_test_city_a")
  end
end
