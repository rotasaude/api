require "rails_helper"

# Regression for the protocol cache invalidation: the dev/prod cache store is
# SolidCache, which does NOT implement #delete_matched. The model's
# after_commit invalidation must work against a store lacking delete_matched.
#
# Transactional since 5c-1 (R15): Rails 8.1 runs after_commit inside the
# (non-joinable) fixture transaction, so no real COMMIT is needed — verified
# with a probe before re-enabling transactions. The real MemoryStore below
# (instead of the :null_store test cache) is what makes the bug visible.
RSpec.describe "Protocol definition cache invalidation", type: :model do
  # A real MemoryStore (caches for real) that raises on delete_matched, exactly
  # like SolidCache::Store does in dev/prod.
  let(:store) do
    Class.new(ActiveSupport::Cache::MemoryStore) do
      def delete_matched(*)
        raise NotImplementedError, "SolidCache::Store does not support delete_matched"
      end
    end.new
  end

  before { allow(Rails).to receive(:cache).and_return(store) }

  def definition(version:, weight:)
    {
      "name" => "dengue", "version" => version, "start_step_id" => "s1",
      "steps" => [
        { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => weight, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }
  end

  it "does not raise on a status change when the cache store lacks delete_matched" do
    expect {
      ProtocolDefinition.create!(name: "dengue", version: 1, status: "active", definition: definition(version: 1, weight: 1))
    }.not_to raise_error
  end

  it "serves the newly activated definition after a republish (cache invalidated)" do
    ProtocolDefinition.create!(name: "dengue", version: 1, status: "active", definition: definition(version: 1, weight: 1))
    expect(Protocols.current(name: "dengue").version).to eq(1)

    ProtocolDefinition.find_by!(name: "dengue", version: 1).update!(status: "retired")
    ProtocolDefinition.create!(name: "dengue", version: 2, status: "active", definition: definition(version: 2, weight: 5))

    expect(Protocols.current(name: "dengue").version).to eq(2)
  end

  # Fix round 1 (M4): the cache key includes CityRecord.current_shard (D4,
  # config/initializers/protocols_facade.rb:44-45) precisely because the
  # store is shared across cities until Plan 5. Both connections below use
  # the SAME `store` instance (stubbed once, above) — if the key did not
  # include the shard, the second read would hit city A's cached entry and
  # wrongly return version 1.
  it "scopes the cache key by city: a protocol cached in TEST_CITY_A is not served in TEST_CITY_B" do
    ProtocolDefinition.create!(name: "dengue", version: 1, status: "active", definition: definition(version: 1, weight: 1))
    expect(Protocols.current(name: "dengue").version).to eq(1) # caches under TEST_CITY_A's shard key

    city_b = create(:city, database_url: city_database_url("rota_saude_test_city_b"))
    CityConnection.with(city_b) do
      ProtocolDefinition.create!(name: "dengue", version: 7, status: "active", definition: definition(version: 7, weight: 9))
      expect(Protocols.current(name: "dengue").version).to eq(7)
    end
  end
end
