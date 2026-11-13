# "Registrada por engano" (módulo 24b, ADR 0052; contrato §2, §13; plano,
# Task 13). Só quem registrou (outro usuário → not_found), com
# `expected_state: "recorded"` e `reason` de 10–500 caracteres depois do strip
# (CollectiveActivities::Catalog::MISTAKEN_REASON; cifrado; nunca no evento, no
# log nem no erro). Trava a atividade (FOR UPDATE): já marcada (ou estado
# esperado diferente) → 409 activity_changed. A linha só ganha os três campos
# de engano (trigger rota_collective_activity_guard). A atividade sai das telas
# e das fontes; a ficha já enfileirada NÃO é desfeita (pendência do §15).
# Evento só com ids.
module CollectiveActivities
  module MarkMistaken
    EVENT = "collective_activity.marked_mistaken".freeze
    STATES = %w[recorded mistaken].freeze

    module_function

    # -> Result.ok(activity:) | fail(:not_found) | fail(:activity_changed)
    #  | fail(:invalid_request, details: { path: "expected_state" | "reason" })
    def call(activity, by:, expected_state:, reason:)
      return Result.fail(:invalid_request, details: { path: "expected_state" }) unless STATES.include?(expected_state)

      text = reason.strip if reason.is_a?(String)
      return Result.fail(:invalid_request, details: { path: "reason" }) unless text && Catalog::MISTAKEN_REASON.cover?(text.length)
      return Result.fail(:not_found) unless Access.marker?(by, activity)

      CollectiveActivity.transaction(requires_new: true) do
        activity.lock!
        next Result.fail(:activity_changed) if activity.mistaken? || expected_state != "recorded"

        activity.update!(mistaken_at: Time.current, mistaken_by_user: by, mistaken_reason: text)
        DomainEvents.publish(EVENT, collective_activity_id: activity.id, user_id: by.id)
        Result.ok(activity: activity)
      end
    end
  end
end
