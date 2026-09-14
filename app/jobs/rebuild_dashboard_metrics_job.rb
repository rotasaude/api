# Reconstrução completa do dashboard a partir das fontes. Ver ADR-0010.
# Wrapper do script para uso via Solid Queue recurring.yml.
#
# Roda uma vez por cidade (EachCityJob), na conexão dela: o banco inteiro é da
# cidade, então as linhas são chaveadas só por (dimension, period, key).
class RebuildDashboardMetricsJob < ApplicationJob
  prepend EachCityJob
  queue_as :housekeeping

  def perform(since: nil)
    buffer = Hash.new(0)
    scope = Triage.where(status: :completed)
    scope = scope.where("completed_at >= ?", Time.parse(since)) if since

    ApplicationRecord.transaction do
      DashboardMetric.delete_all

      scope.find_each(batch_size: 1000) do |triage|
        date = triage.completed_at.to_date.iso8601

        buffer[["triages_by_tier",       date, triage.tier.to_s]] += 1
        buffer[["triages_total",         date, "total"]] += 1
        buffer[["priority_distribution", date, triage.priority.to_s]] += 1
      end

      rows = buffer.map do |(dimension, period, key), value|
        { dimension: dimension, period: period, key: key, value: value,
          created_at: Time.current, updated_at: Time.current }
      end
      DashboardMetric.insert_all(rows) if rows.any?
    end

    Rails.logger.info("[rebuild_dashboard_metrics] inserted=#{buffer.size}")
  end
end
