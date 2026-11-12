# POST /ombudsman/manifestations/:id/forward (ADR 0051; contrato §2; §16 Q8,
# Q32). A equipe encaminha um EXTRATO (nunca o texto original) a um setor da
# secretaria (`department_id`) OU a uma unidade (`health_unit_id`), de
# `in_analysis` ou de `forwarded` (encaminhamentos paralelos), e a manifestação
# fica `forwarded`:
# - exatamente um destino (nenhum → 422 path department_id; os dois → 422
#   path health_unit_id), ativo (senão 422 com o path), com pelo menos um
#   respondente ativo (Access.responder_ids_for) — senão 422
#   destination_without_responder;
# - `extract` em EXTRACT (20..4000, sem as bordas);
# - `due_on` = data local de `now` + forwarding_days (da configuração vigente).
# Sob Ombudsman::Lock, com `expected_state` (409 manifestation_changed, nada
# gravado). Evento `forwarded` (`data: { forwarding_id }`, nunca visível ao
# cidadão) e ombudsman.forwarded { manifestation_id, forwarding_id }.
module Ombudsman
  module Forward
    FROM = %w[in_analysis forwarded].freeze

    module_function

    # -> Result.ok(manifestation:, forwarding:) | fail(:invalid_request, details: { path:, problems: })
    #  | fail(:destination_without_responder) | fail(:not_found) | fail(:manifestation_changed) | fail(:invalid_transition)
    def call(manifestation_id:, expected_state:, department_id:, health_unit_id:, extract:, by:, now: Time.current)
      return Input.refuse("department_id") if department_id.nil? && health_unit_id.nil?
      return Input.refuse("health_unit_id") if !department_id.nil? && !health_unit_id.nil?

      key, destination_id = department_id.nil? ? [ "health_unit_id", health_unit_id ] : [ "department_id", department_id ]
      return Input.refuse(key) unless Input.uuid?(destination_id)

      text = Input.text(extract, Catalog::EXTRACT)
      return Input.refuse("extract") unless text

      ApplicationRecord.transaction do
        manifestation = Lock.manifestation!(manifestation_id)
        next Result.fail(:not_found) unless manifestation

        refusal = Lock.check(manifestation, expected_state)
        next refusal if refusal
        next Result.fail(:invalid_transition) unless FROM.include?(manifestation.state)

        model = key == "department_id" ? Department : HealthUnit
        next Input.refuse(key) unless model.where(active: true).exists?(id: destination_id)

        destination = { key.to_sym => destination_id.downcase }
        next Result.fail(:destination_without_responder) if Access.responder_ids_for(**destination).empty?

        forwarding = OmbudsmanForwarding.create!(
          ombudsman_manifestation: manifestation, **destination, extract: text, state: "pending", created_by_user: by,
          due_on: Deadlines.forwarding_due_on(now.in_time_zone.to_date, OmbudsmanSetting.current), created_at: now, updated_at: now
        )
        manifestation.update!(state: "forwarded", updated_at: now) unless manifestation.state == "forwarded"
        Forwardings.event!(manifestation, forwarding, "forwarded", by: by, now: now)
        DomainEvents.publish("ombudsman.forwarded", manifestation_id: manifestation.id, forwarding_id: forwarding.id)
        Result.ok(manifestation: manifestation, forwarding: forwarding)
      end
    end
  end
end
