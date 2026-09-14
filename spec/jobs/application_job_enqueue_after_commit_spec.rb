require "rails_helper"

# R40 (final review, Critical): ADR-0004 — a job enqueued inside a CITY
# transaction reaches the queue only after that transaction commits, and never
# on rollback. Since ApplicationRecord < CityRecord, domain writes commit on the
# city's database while solid_queue_jobs lives in the shared one: without the
# deferral, a worker could pick ProcessInboundMessageJob up before its
# InboundMessage exists (RecordNotFound, no retry) or AlertMunicipalityJob
# before its Triage (urgent alert lost).
#
# The transaction below is the city shard's own (asserted), not primary's.
# Under transactional fixtures every pool sits inside a non-joinable fixture
# transaction that ActiveRecord.after_all_transactions_commit ignores, so the
# only transaction deferring the enqueue is the one opened here.
RSpec.describe "ApplicationJob enqueue after the city transaction commits (ADR-0004, R40)", type: :job do
  include ActiveJob::TestHelper

  let(:probe_job) do
    stub_const("R40ProbeJob", Class.new(ApplicationJob) { def perform(*); end })
  end

  def probe_enqueued_count
    enqueued_jobs.count { |j| j["job_class"] == "R40ProbeJob" }
  end

  def open_joinable_transaction_databases
    ActiveRecord.all_open_transactions.map { |t| t.connection.pool.db_config.database }
  end

  it "is enabled on ApplicationJob" do
    expect(ApplicationJob.enqueue_after_transaction_commit).to be(true)
  end

  [["TEST_CITY_A", "rota_saude_test_city_a"], ["TEST_CITY_B", "rota_saude_test_city_b"]].each do |const, database|
    context "on #{const}'s shard" do
      let(:city) { Object.const_get(const) }

      it "is not enqueued while the city transaction is open, and is enqueued once it commits" do
        probe_job
        inside = nil

        CityConnection.with(city) do
          ApplicationRecord.transaction do
            expect(ApplicationRecord.connection_pool.db_config.database).to eq(database)
            expect(open_joinable_transaction_databases).to eq([database])

            CityHarnessProbe.create!(label: "r40")
            R40ProbeJob.perform_later("x")
            inside = probe_enqueued_count
          end
        end

        expect(inside).to eq(0)
        expect(probe_enqueued_count).to eq(1)
      end

      it "is never enqueued when the city transaction rolls back" do
        probe_job

        CityConnection.with(city) do
          ApplicationRecord.transaction do
            expect(open_joinable_transaction_databases).to eq([database])
            R40ProbeJob.perform_later("x")
            raise ActiveRecord::Rollback
          end
        end

        expect(probe_enqueued_count).to eq(0)
      end
    end
  end
end
