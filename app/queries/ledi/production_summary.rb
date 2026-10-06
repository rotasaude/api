# Resumo de uma competência da fila LEDI da cidade corrente (spec §6.5).
# Recusas agrupadas pela mensagem JÁ saneada (Ledi::ErrorText) — nunca dado de
# cidadão.
module Ledi
  module ProductionSummary
    STATUSES = %i[accepted rejected pending sending failed].freeze

    module_function

    def counts(competence)
      grouped = LediOutboxEntry.for_competence(competence).group(:status).count
      STATUSES.to_h { |status| [ status, grouped.fetch(status.to_s, 0) ] }
    end

    def rejections(competence)
      LediOutboxEntry.for_competence(competence).where(status: "rejected").group(:last_error).count
                     .sort_by { |message, count| [ -count, message ] }
                     .map { |message, count| { message: message, count: count } }
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
