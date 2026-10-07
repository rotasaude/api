# Resumo de uma competência da fila LEDI da cidade corrente (spec §6.5).
# Recusas agrupadas por campo e código — nunca texto do PEC.
module Ledi
  module ProductionSummary
    STATUSES = %i[accepted rejected pending sending failed].freeze

    module_function

    def counts(competence)
      grouped = LediOutboxEntry.for_competence(competence).group(:status).count
      STATUSES.to_h { |status| [ status, grouped.fetch(status.to_s, 0) ] }
    end

    # api#43: recusas agrupadas por campo e código (nunca texto do PEC).
    def rejections(competence)
      LediOutboxEntry.for_competence(competence).where(status: "rejected")
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
