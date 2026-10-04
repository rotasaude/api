# Agregados pré-computados para o painel da cidade. Ver ADR-0010.
# Atualização incremental por UpdateDashboardJob; reconstrução total por
# RebuildDashboardMetricsJob. O banco é da cidade: a chave é (dimension, period, key).
class DashboardMetric < ApplicationRecord
  # Dimensões que contam triagem concluída (api#34: só a não revogada).
  TRIAGE_DIMENSIONS = %w[triages_by_tier triages_total priority_distribution].freeze

  validates :dimension, :period, :key, presence: true

  # Contagens das dimensões de triagem a partir da fonte, por dia de conclusão
  # (Triage.counted_completed: concluída e não revogada). Fonte única da
  # reconstrução noturna e do recálculo do dia depois de uma revogação.
  def self.triage_counts(triages, into: Hash.new(0))
    triages.counted_completed.find_each(batch_size: 1000) do |triage|
      date = triage.completed_at.to_date.iso8601

      into[["triages_by_tier",       date, triage.tier.to_s]] += 1
      into[["triages_total",         date, "total"]] += 1
      into[["priority_distribution", date, triage.priority.to_s]] += 1
    end
    into
  end

  # Recalcula da fonte as dimensões de triagem de um dia ("AAAA-MM-DD", no fuso
  # da aplicação, como o rebuild): o resultado é o mesmo do rebuild para o dia,
  # sem depender do tier da triagem revogada (o anonimizador o apaga).
  def self.recompute_triage_day!(date)
    transaction do
      where(dimension: TRIAGE_DIMENSIONS, period: date).delete_all
      counts = triage_counts(Triage.where(completed_at: Date.iso8601(date).in_time_zone.all_day))
      now = Time.current
      rows = counts.map do |(dimension, period, key), value|
        { dimension: dimension, period: period, key: key, value: value, created_at: now, updated_at: now }
      end
      # upsert, não insert_all: um bump! (UpdateDashboardJob) ou o rebuild de
      # outra thread da fila :reports pode gravar a mesma chave entre o delete
      # e aqui — insert_all a pularia em silêncio e o dia ficaria com o valor
      # dele. A fonte vence.
      if rows.any?
        upsert_all(rows, unique_by: %i[dimension period key],
                         on_duplicate: Arel.sql("value = EXCLUDED.value, updated_at = EXCLUDED.updated_at"))
      end
    end
  end

  def self.bump!(dimension:, period:, key:, by: 1)
    upsert(
      {
        dimension: dimension,
        period: period,
        key: key,
        value: by,
        updated_at: Time.current
      },
      on_duplicate: Arel.sql("value = dashboard_metrics.value + EXCLUDED.value, updated_at = EXCLUDED.updated_at"),
      unique_by: %i[dimension period key]
    )
  end
end
