# O complemento recebido (ADR 0051; contrato §2; §16 Q8, Q25; preflight F-8):
# a equipe registra o que chegou por outro canal
# (POST /ombudsman/manifestations/:id/complement { expected_state, text,
# attachment_ids? }) e o cidadão responde pelo wpda (Task 15, `actor:
# "citizen"`, a sessão como dono dos anexos). Uma regra para os dois:
# - de `awaiting_complement` para `in_analysis`;
# - `suspended_days += dias corridos entre o pedido e a resposta`, nas DATAS
#   LOCAIS da cidade (Time.zone dentro de CityConnection.with): pedido às 23h
#   e resposta à 0h10 somam 1; pedido e resposta no mesmo dia local, 0;
# - `complement_requested_at` volta a nulo (Q25/A27): o job diário (Task 17)
#   só olha `awaiting_complement`, e o pedido seguinte do ciclo já é recusado
#   por `complement_used`;
# - texto em TEXT (10..4000, sem as bordas; F-8: o mesmo para o `body` do
#   cidadão — `field` dá o nome do campo na recusa);
# - evento `complement_received` visível, com o texto, e os anexos do dono
#   ligados a ele (Attachments.link!, na transação, depois da trava); anexo
#   recusado desfaz tudo.
# Sem aviso (quem respondeu foi o próprio manifestante). Sob Ombudsman::Lock,
# com `expected_state` (409 manifestation_changed).
module Ombudsman
  module RecordComplement
    ACTORS = %w[staff citizen].freeze

    module_function

    # -> Result.ok(manifestation:, event:, attachments:) | fail(:invalid_request, details: { path:, problems: })
    #  | fail(:too_many_attachments) | fail(:not_found) | fail(:manifestation_changed) | fail(:invalid_transition)
    def call(manifestation:, expected_state:, text:, attachment_ids:, actor:, by:, owner:, field: "text", now: Time.current)
      raise ArgumentError, "actor" unless ACTORS.include?(actor)

      value = Input.text(text, Catalog::TEXT)
      return Input.refuse(field) unless value

      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        locked = Lock.manifestation!(manifestation.id)
        result = locked ? receive(locked, expected_state, value, attachment_ids, actor, by, owner, now) : Result.fail(:not_found)
        raise ActiveRecord::Rollback if result.failure?
      end
      result
    end

    def receive(manifestation, expected_state, text, attachment_ids, actor, by, owner, now)
      refusal = Lock.check(manifestation, expected_state)
      return refusal if refusal
      return Result.fail(:invalid_transition) unless manifestation.state == "awaiting_complement"

      manifestation.update!(state: "in_analysis", suspended_days: manifestation.suspended_days + suspended(manifestation, now),
                            complement_requested_at: nil, updated_at: now)
      event = OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: "complement_received", actor: actor,
                                     actor_user: (by if actor == "staff"), text: text, data: {}, visible_to_citizen: true,
                                     created_at: now)
      linked = Attachments.link!(ids: attachment_ids, manifestation: manifestation, owner: owner, event: event)
      return linked if linked.failure?

      Result.ok(manifestation: manifestation, event: event, attachments: linked.payload.fetch(:attachments))
    end

    # Dias corridos locais entre o pedido e a resposta (nunca negativo).
    def suspended(manifestation, now)
      requested = manifestation.complement_requested_at
      return 0 unless requested

      [ (now.in_time_zone.to_date - requested.in_time_zone.to_date).to_i, 0 ].max
    end

    private_class_method :receive
  end
end
