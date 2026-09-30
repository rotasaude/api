# Consolidação diária do Analytics (ADR 0025; spec 2026-09-30 §4.1).
# Recorrente de cidade: no worker de cada cidade roda só nela (EachCityJob).
# Janela: de hoje − 30 a ontem. Run failed vira falha do job, para aparecer
# nas falhas do Solid Queue além de analytics_runs.
class ConsolidateAnalyticsJob < ApplicationJob
  prepend EachCityJob
  queue_as :housekeeping

  def perform
    from, to = Analytics::Run.scheduled_window
    run = Analytics::Run.call(kind: "scheduled", from: from, to: to)
    if run.nil?
      Rails.logger.info("[consolidate_analytics] city=#{Current.city.slug} outra consolidação em curso: nada a fazer")
    elsif run.status == "failed"
      raise Analytics::Run::Failed, run.error
    end
  end
end
