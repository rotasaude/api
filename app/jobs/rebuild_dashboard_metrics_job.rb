# Reconstrução completa do dashboard a partir das fontes. Ver ADR-0010.
# Wrapper do script para uso via Solid Queue recurring.yml.
#
# Roda uma vez por cidade (EachCityJob), na conexão dela: o banco inteiro é da
# cidade, então as linhas são chaveadas só por (dimension, period, key).
#
# Recria TODA dimensão que apaga (ADR 0022): triagens concluídas e revogações de
# consentimento (consents_revoked, do RecordConsentRevocationJob). Com since:
# (um dia, "AAAA-MM-DD", no fuso da aplicação) apaga e recria só os dias a partir
# dele — os anteriores ficam como estão. Triagem revogada (api#34;
# Triage.revoked) não entra nas dimensões de triagem.
class RebuildDashboardMetricsJob < ApplicationJob
  prepend EachCityJob
  queue_as :housekeeping

  def perform(since: nil)
    from = since && Time.zone.parse(since).beginning_of_day
    buffer = Hash.new(0)

    ApplicationRecord.transaction do
      metrics = DashboardMetric.all
      metrics = metrics.where("period >= ?", from.to_date.iso8601) if from
      metrics.delete_all

      # Concluídas e não revogadas (api#34): DashboardMetric.triage_counts.
      triages = Triage.all
      triages = triages.where("completed_at >= ?", from) if from
      DashboardMetric.triage_counts(triages, into: buffer)

      revoked = Consent.where.not(revoked_at: nil)
      revoked = revoked.where("revoked_at >= ?", from) if from
      revoked.find_each(batch_size: 1000) do |consent|
        buffer[["consents_revoked", consent.revoked_at.to_date.iso8601, "total"]] += 1
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
