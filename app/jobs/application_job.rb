class ApplicationJob < ActiveJob::Base
  # ADR-0004 (R40): a job enqueued inside a transaction reaches the queue only
  # after that transaction COMMITS; on ROLLBACK it is never enqueued. Domain
  # writes commit on the CITY database (ApplicationRecord < CityRecord) while
  # solid_queue_jobs lives in the shared database, so without this a worker can
  # pick a job up before the rows it reads exist.
  #
  # Set here, not via `config.active_job.enqueue_after_transaction_commit`:
  # activejob 8.1 strips that key in its railtie ("can't be applied globally"),
  # so the config was silently inert. ActiveJob::Base (and therefore
  # ActionMailer::MailDeliveryJob, used by deliver_later) keeps the default
  # `false` — mail jobs must carry plain values, never uncommitted records (R42).
  self.enqueue_after_transaction_commit = true

  # Plano 5: job de cidade só na fila da cidade; job de plataforma só na fila de
  # plataforma (PlatformQueue).
  before_enqueue { |job| PlatformQueue.check!(job) }

  retry_on ActiveRecord::Deadlocked, attempts: 3, wait: :polynomially_longer
  discard_on ActiveJob::DeserializationError
end
