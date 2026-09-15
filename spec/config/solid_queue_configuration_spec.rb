require "rails_helper"

# Plano 5 (spec banco-por-cidade §4): cada cidade roda três workers — urgent
# isolado (ADR-0006) — e agenda só tarefas de cidade; a plataforma roda um worker
# e agenda só jobs de plataforma.
RSpec.describe "Solid Queue configuration per city and platform" do
  def config(path, env)
    ActiveSupport::ConfigurationFile.parse(Rails.root.join(path)).fetch(env, {})
  end

  def task_classes(path, env)
    config(path, env).values.filter_map { |task| task["class"] }
  end

  %w[development production].each do |env|
    context env do
      it "gives each city three workers, with urgent alone" do
        queues = config("config/queue.yml", env).fetch("workers").map { |worker| Array(worker["queues"]) }

        expect(queues).to eq([ %w[urgent], %w[realtime default], %w[reports housekeeping] ])
      end

      it "gives the platform workers covering the queues of every platform job and of e-mail delivery" do
        queues = config("config/queue_platform.yml", env).fetch("workers").flat_map { |worker| Array(worker["queues"]) }

        expect(queues).to include(ProvisionCityJob.queue_name, PurgePlatformAccessJob.queue_name, "default")
      end

      it "schedules only platform jobs on the platform and no platform job in a city" do
        expect(task_classes("config/recurring_platform.yml", env)).to all(satisfy { |name| PlatformQueue::JOBS.include?(name) })
        expect(task_classes("config/recurring.yml", env) & PlatformQueue::JOBS).to eq([])
        expect(task_classes("config/recurring.yml", env).map(&:safe_constantize)).to all(be_present)
      end

      it "clears finished jobs in every queue database" do
        expect(config("config/recurring.yml", env)).to have_key("clear_solid_queue_finished")
        expect(config("config/recurring_platform.yml", env)).to have_key("clear_solid_queue_finished")
      end
    end
  end
end
