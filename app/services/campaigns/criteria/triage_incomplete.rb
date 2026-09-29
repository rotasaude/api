# Triagem abandonada (tempo ou cancelamento) criada no período, sem nenhuma
# triagem concluída do mesmo cidadão criada depois dela.
module Campaigns
  module Criteria
    class TriageIncomplete
      NO_LATER_COMPLETION = <<~SQL.squish.freeze
        NOT EXISTS (
          SELECT 1 FROM triages later
          JOIN conversations later_conversation ON later_conversation.id = later.conversation_id
          WHERE later_conversation.citizen_id = conversations.citizen_id
            AND later.status = 'completed'
            AND later.created_at > triages.created_at
        )
      SQL

      def self.relation(params)
        Triage.joins(:conversation)
              .where(status: %w[aborted_by_timeout aborted_by_cancellation], created_at: Criteria.period(params))
              .where.not(conversations: { citizen_id: nil })
              .where(NO_LATER_COMPLETION)
              .select("conversations.citizen_id")
      end
    end
  end
end
