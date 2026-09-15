require "rails_helper"

# Plano 5 (spec banco-por-cidade §1/§4): a fila de cada cidade mora no banco dela;
# fora de cidade, a fila é a de plataforma. Usa o adapter real do Solid Queue —
# o de teste não grava em tabela nenhuma.
RSpec.describe "CityConnection queue routing" do
  around do |example|
    adapter_was = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :solid_queue
    example.run
  ensure
    ActiveJob::Base.queue_adapter = adapter_was
  end

  let(:probe_job) { stub_const("QueueRoutingProbeJob", Class.new(ApplicationJob) { def perform; end }) }

  def probe_jobs
    SolidQueue::Job.where(class_name: "QueueRoutingProbeJob")
  end

  it "enqueues a job inside a city onto that city's own database" do
    probe_job.perform_later

    expect(SolidQueue::Job.connection_db_config.database).to eq("rota_saude_test_city_a")
    expect(probe_jobs.count).to eq(1)
    expect(on_platform_queue { probe_jobs.count }).to eq(0)
  end

  it "keeps two cities' queues apart" do
    CityConnection.with(TEST_CITY_B) { probe_job.perform_later }

    expect(probe_jobs.count).to eq(0)
    expect(CityConnection.with(TEST_CITY_B) { [ SolidQueue::Job.connection_db_config.database, probe_jobs.count ] })
      .to eq([ "rota_saude_test_city_b", 1 ])
  end

  it "enqueues a platform job outside any city onto the platform database" do
    on_platform_queue { PurgePlatformAccessJob.perform_later }

    expect(on_platform_queue { [ SolidQueue::Job.connection_db_config.database,
                                 SolidQueue::Job.where(class_name: "PurgePlatformAccessJob").count ] })
      .to eq([ "rota_saude_platform_test", 1 ])
  end

  it "registers and forgets both pools of a city" do
    city = create(:city, slug: "fila#{SecureRandom.hex(3)}", database_url: city_database_url("rota_saude_test_city_b"))
    handler = ActiveRecord::Base.connection_handler

    CityConnection.ensure_pool(city)
    # T2-c: forget lived after this expectation, unguarded — a failure here
    # would raise past it and leak the pool this example just registered into
    # every later example in the process. Guard the risky assertion so forget
    # always runs, pass or fail.
    begin
      expect(handler.retrieve_connection_pool("SolidQueue::Record", role: :writing, shard: city.shard)).to be_present
    ensure
      CityConnection.forget(city.shard)
    end

    expect(handler.retrieve_connection_pool("CityRecord", role: :writing, shard: city.shard)).to be_nil
    expect(handler.retrieve_connection_pool("SolidQueue::Record", role: :writing, shard: city.shard)).to be_nil
  end
end
