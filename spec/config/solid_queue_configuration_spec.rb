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

      it "serves the queue of every recurring task from a worker in the paired queue file" do
        # Fix round 1, Important: a recurring task with no queue served by any
        # worker in its own queue file piles up unclaimed forever (this is how
        # clear_solid_queue_finished, a command: task with no queue:, went
        # unnoticed — it defaults to SolidQueue::RecurringJob's queue_as
        # (solid_queue_recurring), which no worker below serves).
        [
          [ "config/queue.yml", "config/recurring.yml" ],
          [ "config/queue_platform.yml", "config/recurring_platform.yml" ]
        ].each do |queue_path, recurring_path|
          served = config(queue_path, env).fetch("workers").flat_map { |worker| Array(worker["queues"]) }

          config(recurring_path, env).each do |key, task|
            queue = task["queue"] || (task["class"] ? task["class"].constantize.queue_name : SolidQueue::RecurringJob.queue_name)

            expect(served).to(
              include(queue).or(include("*")),
              "#{recurring_path} task #{key.inspect} needs queue #{queue.inspect}; " \
                "#{queue_path} only serves #{served.inspect}"
            )
          end
        end
      end
    end
  end

  # Solid Queue valida pool ≥ maior número de threads de um worker + 2 contra o
  # pool do banco do processo (RAILS_MAX_THREADS do worker).
  it "gives the Kamal worker a database pool that fits the largest worker" do
    %w[development production].each do |env|
      deploy = YAML.safe_load(Rails.root.join("deploy/#{env}/deploy.yml").read)
      pool = Integer(deploy.dig("servers", "worker", "env", "clear", "RAILS_MAX_THREADS"))
      threads = config("config/queue.yml", env).fetch("workers").map { |worker| worker["threads"] }.max

      expect(pool).to be >= threads + 2, "deploy/#{env}/deploy.yml: RAILS_MAX_THREADS #{pool} < #{threads} + 2"
      expect(deploy.dig("servers", "worker", "cmd")).to eq("./bin/city_workers")
    end
  end
end
