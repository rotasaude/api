# GET /admin/api/queues — Solid Queue (§4.7).
#
# Painel de maior valor operacional. Reúne profundidade por fila, idade do
# pendente mais antigo, execuções falhadas (apresentação) e status das
# recurring tasks.
#
# RESSALVA HONESTA (§5 do brief): este painel não vê o no-op silencioso
# causado pelo bug de idempotência (processed_events gravado antes do
# efeito) — fila "verde" NÃO equivale a "entrega garantida". Mantemos
# essa ressalva no centro de notificações do frontend.
class Admin::QueuesQuery
  URGENT_QUEUE = "urgent".freeze

  # Filas internas do Solid Queue (ex.: solid_queue_recurring, usada pelo
  # próprio scheduler para enfileirar execuções de recurring tasks). Não são
  # trabalho da aplicação — escondemos do painel para não inflar KPIs.
  INTERNAL_QUEUE_PREFIX = "solid_queue_".freeze

  def self.application_queue?(name)
    return false if name.blank?
    !name.to_s.start_with?(INTERNAL_QUEUE_PREFIX)
  end

  def self.call
    {
      queues: per_queue,
      oldestPendingS: oldest_pending_seconds,
      failedExecutions: failed_executions,
      recurring: recurring_tasks
    }
  end

  def self.per_queue
    queue_names = SolidQueue::Job.distinct.pluck(:queue_name).compact
    queue_names.select { |n| application_queue?(n) }.map do |name|
      depth = SolidQueue::ReadyExecution.where(queue_name: name).count
      scheduled = SolidQueue::ScheduledExecution.where(queue_name: name).count
      failed_jobs = SolidQueue::FailedExecution.joins(:job).where(solid_queue_jobs: { queue_name: name }).count
      running = SolidQueue::ClaimedExecution.joins(:job).where(solid_queue_jobs: { queue_name: name }).count
      oldest = SolidQueue::ReadyExecution.where(queue_name: name).minimum(:created_at)
      oldest_s = oldest ? (Time.current - oldest).to_i : 0

      {
        name: name,
        urgent: name == URGENT_QUEUE,
        depth: depth,
        oldestS: oldest_s,
        running: running,
        scheduled: scheduled,
        failed: failed_jobs,
        tone: tone(depth: depth, oldest_s: oldest_s, failed: failed_jobs, urgent: name == URGENT_QUEUE)
      }
    end
  end

  def self.oldest_pending_seconds
    oldest = SolidQueue::ReadyExecution
               .where.not("queue_name LIKE ?", "#{INTERNAL_QUEUE_PREFIX}%")
               .minimum(:created_at)
    return 0 unless oldest
    (Time.current - oldest).to_i
  end

  def self.failed_executions
    SolidQueue::FailedExecution
      .joins(:job)
      .order(created_at: :desc)
      .limit(20)
      .map do |fe|
        job = fe.job
        {
          jobClass: job.class_name,
          queue: job.queue_name,
          error: fe.error.to_s.lines.first&.strip,
          attempts: nil,
          at: fe.created_at.strftime("%H:%M"),
          ref: nil
        }
      end
  end

  def self.recurring_tasks
    SolidQueue::RecurringTask.order(:key).map do |task|
      last_run = SolidQueue::RecurringExecution.where(task_key: task.key).order(run_at: :desc).first
      last_ago = last_run ? "há #{((Time.current - last_run.run_at) / 60).to_i} min" : "—"
      delayed_min = last_run ? ((Time.current - last_run.run_at) / 60).to_i : 0
      {
        key: task.key,
        name: task.description.presence || task.key,
        schedule: task.schedule,
        lastAgo: last_ago,
        delayedMin: delayed_min,
        status: delayed_min > 60 ? "warn" : "ok",
        adr: nil
      }
    end
  end

  def self.tone(depth:, oldest_s:, failed:, urgent:)
    return "down" if urgent && (oldest_s > 60 || failed.positive?)
    return "warn" if failed.positive? || oldest_s > 300
    return "info" if depth.positive?
    "ok"
  end
end
