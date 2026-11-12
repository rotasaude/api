# POST /ombudsman/manifestations/:id/reopen (ADR 0051; contrato §2; §16 Q8,
# Q10, Q32; carry T14). O ouvidor reabre, de ofício, uma manifestação
# `answered` ou `archived`: volta a `in_analysis` num ciclo novo.
# - `text` opcional, em TEXT (10..4000, sem as bordas) → 422 path text;
# - `cycle += 1`, `cycle_started_on` = a data local de `now` (o prazo novo
#   conta de hoje); zera `extended`, `extension_reason`, `complement_used`,
#   `complement_requested_at`, `suspended_days`, `resolution`, `concluded_at`
#   e `archive_reason`, `duplicate_of_id` e `external_body_name` JUNTOS (os
#   CHECKs usam IS NOT DISTINCT FROM: estado, motivo e as duas colunas têm de
#   sair no mesmo UPDATE);
# - evento `reopened` visível, ombudsman.reopened { manifestation_id };
# - se o cidadão tinha um pedido de reabertura PENDENTE, a reabertura o
#   aceita (decidido por quem reabriu) e o cidadão recebe o aviso
#   `reopen_decided` (a ÚLTIMA escrita — F-24); senão ficaria pendente num
#   ciclo já passado e travaria o pedido seguinte.
# O texto do evento `reopened` é INTERNO: o cidadão vê que reabriu, não o
# texto (Timeline::TEXT_KINDS não inclui `reopened`).
# `Reopen.apply!` é o mesmo passo, sobre a manifestação já travada, usado ao
# aceitar o pedido (Ombudsman::DecideReopen). Sob Ombudsman::Lock, com
# `expected_state` (409 manifestation_changed).
module Ombudsman
  module Reopen
    FROM = %w[answered archived].freeze

    module_function

    # -> Result.ok(manifestation:) | fail(:invalid_request, details: { path: "text", problems: })
    #  | fail(:not_found) | fail(:manifestation_changed) | fail(:invalid_transition)
    def call(manifestation_id:, expected_state:, text:, by:, now: Time.current)
      value = nil
      unless text.nil?
        value = Input.text(text, Catalog::TEXT)
        return Input.refuse("text") unless value
      end

      ApplicationRecord.transaction do
        manifestation = Lock.manifestation!(manifestation_id)
        next Result.fail(:not_found) unless manifestation

        refusal = Lock.check(manifestation, expected_state)
        next refusal if refusal
        next Result.fail(:invalid_transition) unless FROM.include?(manifestation.state)

        pending = OmbudsmanReopenRequest.lock("FOR UPDATE").find_by(ombudsman_manifestation_id: manifestation.id, state: "pending")
        raise ArgumentError, "by" if pending && !by.is_a?(User)

        apply!(manifestation, text: value, by: by, now: now)
        if pending
          pending.update!(state: "accepted", decided_by_user: by, decided_at: now, updated_at: now)
          Notify.call(manifestation: manifestation, kind: "reopen_decided", now: now)
        end
        Result.ok(manifestation: manifestation)
      end
    end

    # A manifestação já travada e em estado final. Não envia aviso (quem chama decide).
    def apply!(manifestation, text:, by:, now:)
      cycle = manifestation.cycle + 1
      manifestation.update!(state: "in_analysis", cycle: cycle, cycle_started_on: now.in_time_zone.to_date, extended: false,
                            extension_reason: nil, complement_used: false, complement_requested_at: nil, suspended_days: 0,
                            resolution: nil, archive_reason: nil, duplicate_of_id: nil, external_body_name: nil,
                            concluded_at: nil, updated_at: now)
      OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: "reopened", actor: "staff", actor_user: by, text: text,
                             data: { "cycle" => cycle }, visible_to_citizen: true, created_at: now)
      DomainEvents.publish("ombudsman.reopened", manifestation_id: manifestation.id)
    end
  end
end
