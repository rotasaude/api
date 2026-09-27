require "rails_helper"

# F-05.11: o painel Filas lê o Solid Queue do banco da cidade (Plano 5),
# esconde as filas internas do scheduler e pinta a fila urgent de vermelho
# assim que ela atrasa ou falha (ADR 0006).
RSpec.describe Admin::QueuesQuery do
  around do |example|
    adapter_was = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :solid_queue
    example.run
  ensure
    ActiveJob::Base.queue_adapter = adapter_was
  end

  def enqueue!(queue)
    SolidQueue::Job.create!(class_name: "ProbeJob", queue_name: queue, arguments: {}, active_job_id: SecureRandom.uuid)
  end

  it "lists the application queues and hides the scheduler's internal ones" do
    enqueue!("reports")
    enqueue!("solid_queue_recurring")

    names = described_class.call[:queues].map { |q| q[:name] }
    expect(names).to include("reports")
    expect(names).not_to include("solid_queue_recurring")
  end

  it "reports depth and the tone of a queue with ready work" do
    enqueue!("reports")

    queue = described_class.call[:queues].find { |q| q[:name] == "reports" }
    expect(queue).to include(depth: 1, urgent: false, tone: "info")
  end

  it "turns the urgent queue red once its oldest job waits over a minute" do
    enqueue!("urgent")
    SolidQueue::ReadyExecution.where(queue_name: "urgent").update_all(created_at: 2.minutes.ago)

    queue = described_class.call[:queues].find { |q| q[:name] == "urgent" }
    expect(queue).to include(urgent: true, tone: "down")
  end

  it "reads only this city's queue" do
    enqueue!("reports")
    CityConnection.with(TEST_CITY_B) { enqueue!("housekeeping") }

    names = described_class.call[:queues].map { |q| q[:name] }
    expect(names).to include("reports")
    expect(names).not_to include("housekeeping")
  end
end
