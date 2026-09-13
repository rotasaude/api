require "rails_helper"

RSpec.describe CityRecord do
  it "defaults to the bootstrap shard, with no city selected" do
    expect(CityRecord.default_shard).to eq(:bootstrap)
  end

  it "fails closed outside a city connection" do
    CityRecord.connected_to(shard: :bootstrap, role: :writing) do
      expect(CityRecord.connection_db_config.database).to eq("rota_saude_no_city_selected")
    end

    expect {
      CityRecord.connected_to(shard: :bootstrap, role: :writing) { CityHarnessProbe.count }
    }.to raise_error(ActiveRecord::StatementInvalid, /relation "probes" does not exist/)
  end

  it "still serves a real city" do
    within_city(TEST_CITY_B) do
      expect(CityRecord.connection_db_config.database).to eq("rota_saude_test_city_b")
    end
  end

  it "declares connects_to exactly once" do
    source = File.read(Rails.root.join("app/models/city_record.rb"), encoding: "UTF-8")
    expect(source.scan(/^\s*connects_to\b/).size).to eq(1)
  end
end
