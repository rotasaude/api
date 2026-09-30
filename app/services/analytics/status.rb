module Analytics
  # Estado do pipeline da cidade (contratos §1 e §3), lido de analytics_runs.
  # `as_of` do Analytics = last_succeeded_at; stale = nunca consolidou ou há
  # mais de 36 h. last_error é o do run mais recente (falha dele ou da
  # publicação dele).
  class Status
    STALE_AFTER = 36.hours
    Snapshot = Struct.new(:last_run_status, :last_succeeded_at, :last_published_at, :last_error, :stale,
                          keyword_init: true)

    def self.call(now: Time.current)
      last = AnalyticsRun.order(started_at: :desc, id: :desc).first
      succeeded_at = AnalyticsRun.where(status: "succeeded").maximum(:finished_at)
      Snapshot.new(last_run_status: last&.status, last_succeeded_at: succeeded_at,
                   last_published_at: AnalyticsRun.maximum(:published_at), last_error: last&.error,
                   stale: succeeded_at.nil? || succeeded_at < now - STALE_AFTER)
    end
  end
end
