require "rails_helper"
require Rails.root.join("spec/support/admin_rls")

# Regression for the protocol cache invalidation: the dev/prod cache store is
# SolidCache, which does NOT implement #delete_matched. The model's
# after_commit invalidation must work against a store lacking delete_matched.
#
# Why use_transactional_tests = false: after_commit callbacks only fire on a
# real COMMIT — inside the usual rolled-back test transaction they never run,
# which (together with the :null_store test cache) is why this bug was invisible.
RSpec.describe "Protocol definition cache invalidation", type: :model do
  self.use_transactional_tests = false

  before { clean_admin_tables }
  after  { clean_admin_tables }

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

  let(:muni) do
    as_admin { Municipality.create!(name: "Cache City", slug: "cache-city", ibge_code: "3500009") }
  end

  it "does not raise on a status change when the cache store lacks delete_matched" do
    expect {
      as_admin do
        ProtocolDefinition.create!(
          municipality_id: muni.id, name: "dengue", version: 1, status: "active",
          definition: definition(version: 1, weight: 1)
        )
      end
    }.not_to raise_error
  end

  it "serves the newly activated definition after a republish (cache invalidated)" do
    as_admin do
      ProtocolDefinition.create!(
        municipality_id: muni.id, name: "dengue", version: 1, status: "active",
        definition: definition(version: 1, weight: 1)
      )
    end
    expect(as_admin { Protocols.current(muni.id, name: "dengue") }.version).to eq(1)

    as_admin do
      ProtocolDefinition.find_by!(name: "dengue", version: 1, municipality_id: muni.id).update!(status: "retired")
      ProtocolDefinition.create!(
        municipality_id: muni.id, name: "dengue", version: 2, status: "active",
        definition: definition(version: 2, weight: 5)
      )
    end

    expect(as_admin { Protocols.current(muni.id, name: "dengue") }.version).to eq(2)
  end
end
