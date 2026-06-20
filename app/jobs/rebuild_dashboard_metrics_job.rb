# Reconstrução completa do dashboard a partir das fontes. Ver ADR-0007.
# Wrapper do script para uso via Solid Queue recurring.yml.
class RebuildDashboardMetricsJob < ApplicationJob
  include AdminRoleJob
  queue_as :housekeeping

  def perform(since: nil)
    buffer = Hash.new(0)
    scope = Triagem.where(status: :completed)
    scope = scope.where("completed_at >= ?", Time.parse(since)) if since

    ApplicationRecord.transaction do
      DashboardMetric.delete_all

      scope.find_each(batch_size: 1000) do |triagem|
        municipality_id = triagem.conversation.municipality_id
        next unless municipality_id
        date = triagem.completed_at.to_date.iso8601

        buffer[[municipality_id, "triagens_by_tier",        date, triagem.tier.to_s]] += 1
        buffer[[municipality_id, "triagens_total",          date, "total"]] += 1
        buffer[[municipality_id, "priority_distribution",   date, triagem.priority.to_s]] += 1
      end

      rows = buffer.map do |(municipality_id, dimension, period, key), value|
        { municipality_id: municipality_id, dimension: dimension,
          period: period, key: key, value: value,
          created_at: Time.current, updated_at: Time.current }
      end
      DashboardMetric.insert_all(rows) if rows.any?
    end

    Rails.logger.info("[rebuild_dashboard_metrics] inserted=#{buffer.size}")
  end
end
