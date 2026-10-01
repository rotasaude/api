require "rails_helper"

# api#31: jobs que falharam guardam os argumentos (telefone, e-mail) para sempre;
# descartamos os com mais de 30 dias, junto com a linha do job.
RSpec.describe SolidQueueRetention do
  def job!(finished_at: nil)
    SolidQueue::Job.create!(class_name: "ProbeJob", queue_name: "default", active_job_id: SecureRandom.uuid,
                            arguments: { phone: "5541999990001" }, finished_at: finished_at)
  end

  def failed!(created_at:)
    job = job!
    SolidQueue::FailedExecution.create!(job: job, error: { message: "boom" }, created_at: created_at)
    job
  end

  it "pins the retention at 30 days" do
    expect(described_class::FAILED_RETENTION).to eq(30.days)
  end

  it "discards failed executions older than the age, with their job row, and keeps recent ones" do
    old = failed!(created_at: 31.days.ago)
    recent = failed!(created_at: 29.days.ago)

    described_class.discard_failed_older_than(30.days)

    expect(SolidQueue::Job.exists?(old.id)).to be(false)
    expect(SolidQueue::FailedExecution.where(job_id: old.id)).to be_empty
    expect(SolidQueue::Job.exists?(recent.id)).to be(true)
    expect(SolidQueue::FailedExecution.where(job_id: recent.id)).to exist
  end

  it "leaves ready and finished jobs untouched, however old" do
    ready = job!
    SolidQueue::ReadyExecution.where(job_id: ready.id).update_all(created_at: 60.days.ago)
    finished = job!(finished_at: 60.days.ago)

    expect { described_class.discard_failed_older_than(30.days) }
      .not_to(change { [ SolidQueue::Job.count, SolidQueue::ReadyExecution.count ] })
    expect(SolidQueue::Job.exists?(finished.id)).to be(true)
  end

  it "returns the number discarded" do
    failed!(created_at: 40.days.ago)
    failed!(created_at: 41.days.ago)

    expect(described_class.discard_failed_older_than(30.days)).to eq(2)
  end

  it "defaults to FAILED_RETENTION" do
    old = failed!(created_at: 31.days.ago)

    described_class.discard_failed

    expect(SolidQueue::Job.exists?(old.id)).to be(false)
  end

  describe "schedule" do
    %w[config/recurring.yml config/recurring_platform.yml].each do |path|
      it "is scheduled daily in #{path} on a served queue" do
        task = ActiveSupport::ConfigurationFile.parse(Rails.root.join(path)).fetch("production").fetch("discard_old_failed_jobs")

        expect(task["command"]).to eq("SolidQueueRetention.discard_failed")
        expect(task["schedule"]).to match(/every day/)
        expect(task["queue"]).to eq("housekeeping")
      end
    end
  end

  # Pino: jobs terminados já saem de hora em hora, com o prazo padrão do gem.
  describe "finished jobs cleanup" do
    %w[config/recurring.yml config/recurring_platform.yml].each do |path|
      it "keeps clear_solid_queue_finished hourly in #{path}" do
        task = ActiveSupport::ConfigurationFile.parse(Rails.root.join(path)).fetch("production").fetch("clear_solid_queue_finished")

        expect(task["command"]).to include("clear_finished_in_batches")
        expect(task["schedule"]).to match(/every hour/)
        expect(task["queue"]).to eq("housekeeping")
      end
    end

    it "does not raise the finished-job age above one day" do
      expect(SolidQueue.clear_finished_jobs_after).to be <= 1.day
    end
  end
end
