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
# Módulo 35b (§4, Q13), com `zoonoses:` (o gate, lido fora da transação):
# - a UVZ (unidade environmental_surveillance) conta com respondente quando
#   há alguém da equipe do centro (Access.responder_ids_for);
# - o encaminhamento à UVZ cria, na mesma transação, a zoonoses_demands
#   `open` (Zoonoses::OpenDemand.demand!; subtipo do `code` do assunto, ou
#   `other`) — vale para o encaminhamento manual da equipe e para o
#   automático;
# - `by: nil` é o automático (Zoonoses::OpenDemand): `created_by_system`, e o
#   evento com o ator `system`.
# Q34: outro encaminhamento `pending` da mesma manifestação ao mesmo destino
# → 409 forwarding_already_pending (path destination), nada gravado; vale para
# o manual e o automático, sob a trava da manifestação. Respondido, recusado
# ou cancelado o primeiro, o novo passa (e, na UVZ, cria outra demanda).
module Ombudsman
  module Forward
    FROM = %w[in_analysis forwarded].freeze

    module_function

    # -> Result.ok(manifestation:, forwarding:, demand:) (demand nil fora da UVZ com o gate)
    #  | fail(:invalid_request, details: { path:, problems: })
    #  | fail(:destination_without_responder) | fail(:not_found) | fail(:manifestation_changed) | fail(:invalid_transition)
    #  | fail(:forwarding_already_pending, details: { path: "destination", problems: })
    def call(manifestation_id:, expected_state:, department_id:, health_unit_id:, extract:, by:, zoonoses: false, now: Time.current)
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
        target = model.where(active: true).find_by(id: destination_id)
        next Input.refuse(key) unless target

        destination = { key.to_sym => destination_id.downcase }
        next Result.fail(:destination_without_responder) if Access.responder_ids_for(**destination, zoonoses: zoonoses).empty?
        if OmbudsmanForwarding.where(ombudsman_manifestation_id: manifestation.id, state: "pending", **destination).exists?
          next Input.refuse("destination", :forwarding_already_pending)
        end

        forwarding = OmbudsmanForwarding.create!(
          ombudsman_manifestation: manifestation, **destination, extract: text, state: "pending", created_by_user: by,
          created_by_system: by.nil?,
          due_on: Deadlines.forwarding_due_on(now.in_time_zone.to_date, OmbudsmanSetting.current), created_at: now, updated_at: now
        )
        manifestation.update!(state: "forwarded", updated_at: now) unless manifestation.state == "forwarded"
        Forwardings.event!(manifestation, forwarding, "forwarded", by: by, now: now)
        DomainEvents.publish("ombudsman.forwarded", manifestation_id: manifestation.id, forwarding_id: forwarding.id)
        demand = (Zoonoses::OpenDemand.demand!(forwarding: forwarding, manifestation: manifestation, now: now) if zoonoses && uvz?(target))
        Result.ok(manifestation: manifestation, forwarding: forwarding, demand: demand)
      end
    end

    def uvz?(target) = target.is_a?(HealthUnit) && target.kind == Zoonoses::Access::UNIT_KIND

    private_class_method :uvz?
  end
end
