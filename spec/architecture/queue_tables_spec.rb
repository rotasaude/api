require "rails_helper"

# Plano 5 (spec banco-por-cidade §2/§4): a fila de cada cidade mora no banco dela;
# a fila de plataforma e o Solid Cache, no banco de plataforma.
RSpec.describe "Solid Queue and Solid Cache tables" do
  def solid_queue_tables
    %w[solid_queue_blocked_executions solid_queue_claimed_executions solid_queue_failed_executions
       solid_queue_jobs solid_queue_pauses solid_queue_processes solid_queue_ready_executions
       solid_queue_recurring_executions solid_queue_recurring_tasks solid_queue_scheduled_executions
       solid_queue_semaphores]
  end

  it "has the queue and the cache in the platform database" do
    expect(PlatformRecord.connection.tables).to include(*solid_queue_tables, "solid_cache_entries")
  end

  it "has the queue, and no cache, in a city database" do
    tables = CityRecord.connection.tables

    expect(tables).to include(*solid_queue_tables)
    expect(tables).not_to include("solid_cache_entries")
  end
end
