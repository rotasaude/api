# Resumo de uma competência da fila LEDI da cidade corrente (spec §6.5).
# Recusas agrupadas por campo e código — nunca texto do PEC.
# Recusada já regerada (existe linha nova com replaces_outbox_id = id; spec
# §5) não conta mais: a pendência passou para a linha nova. Vale para as
# contagens, as recusas e, por elas, o alerta (Ledi::Alert) e o resumo que o
# console lê (Ledi::PublishProductionJob).
module Ledi
  module ProductionSummary
    STATUSES = %i[accepted rejected pending sending failed].freeze
    NOT_REGENERATED_SQL = "NOT EXISTS (SELECT 1 FROM ledi_outbox replacements " \
                          "WHERE replacements.replaces_outbox_id = ledi_outbox.id)".freeze

    module_function

    # A fila da competência sem as recusadas que já foram regeradas.
    def current_entries(competence)
      LediOutboxEntry.for_competence(competence)
                     .where("ledi_outbox.status <> 'rejected' OR #{NOT_REGENERATED_SQL}")
    end

    def counts(competence)
      grouped = current_entries(competence).group(:status).count
      STATUSES.to_h { |status| [ status, grouped.fetch(status.to_s, 0) ] }
    end

    # api#43: recusas agrupadas por campo e código (nunca texto do PEC).
    def rejections(competence)
      current_entries(competence).where(status: "rejected")
                     .joins("CROSS JOIN LATERAL jsonb_array_elements(ledi_outbox.last_error_codes) AS error_code")
                     .group(Arel.sql("error_code->>'field'"), Arel.sql("error_code->>'code'")).count
                     .map { |(field, code), count| { field: field, code: code, count: count } }
                     .sort_by { |row| [ -row[:count], row[:field], row[:code] ] }
    end

    def call(competence:, today:, record_mode:)
      totals = counts(competence)
      left = Ledi::Deadline.business_days_left(competence, today: today)
      { competence: competence, deadline_on: Ledi::Deadline.on(competence), business_days_left: left,
        alert: Ledi::Alert.level(counts: totals, business_days_left: left, record_mode: record_mode),
        counts: totals, rejections: rejections(competence) }
    end
  end
end
