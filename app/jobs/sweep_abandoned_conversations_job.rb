# Varredura recorrente (ADR-0019): marca conversas ociosas não-terminais como
# `abandoned` e aborta a triage in_progress (`aborted_by_timeout`). Cross-tenant
# sob a conexão admin (BYPASSRLS) — ver AdminRoleJob. Silenciosa (sem outbound).
class SweepAbandonedConversationsJob < ApplicationJob
  prepend AdminRoleJob
  queue_as :housekeeping

  NON_TERMINAL = %w[greeting awaiting_consent consented].freeze

  def perform(idle_hours: 24)
    cutoff = idle_hours.hours.ago

    fresh_triage_ids = Triage.where(status: :in_progress).where("updated_at >= ?", cutoff).select(:conversation_id)
    completed_ids    = Triage.where(status: :completed).select(:conversation_id)

    scope = Conversation
              .where(state: NON_TERMINAL)
              .where("updated_at < ?", cutoff)
              .where.not(id: fresh_triage_ids)
              .where.not(id: completed_ids)

    abandoned = 0
    scope.find_each do |conversation|
      conversation.triages.where(status: :in_progress)
                  .update_all(status: "aborted_by_timeout", updated_at: Time.current)
      conversation.update_columns(state: "abandoned", updated_at: Time.current)
      abandoned += 1
    end

    Rails.logger.info("[sweep_abandoned] abandoned=#{abandoned} idle_hours=#{idle_hours} cutoff=#{cutoff.iso8601}")
  end
end
