# POST /ombudsman/manifestations/:id/final_response (ADR 0051; contrato §2,
# §9; §16 Q8, Q32; preflight F-10). A equipe conclui o ciclo com a resposta
# conclusiva: `in_analysis` → `answered`, `concluded_at = now`:
# - `text` em TEXT (10..4000, sem as bordas);
# - `resolution` (RESOLUTIONS) obrigatória em reclamação, solicitação e
#   denúncia (RESOLUTION_KINDS) e proibida nos outros tipos → 422
#   `path: "resolution"`;
# - com encaminhamento `pending` → 422 forwarding_pending. F-10: o pendente só
#   existe em `forwarded`, que não é estado de origem; com `expected_state`
#   igual, `forwarded` responde forwarding_pending (o motivo específico
#   vence) e todo outro estado fora da tabela, invalid_transition;
# - na anônima o texto fica interno (evento `visible_to_citizen = false`) e
#   não há aviso (não há cidadão).
# Evento `final_response` (`data: { resolution }` quando há),
# ombudsman.concluded { manifestation_id, outcome: "answered" } e o aviso
# `final_response` (Ombudsman::Notify, a ÚLTIMA escrita — F-24). Sob
# Ombudsman::Lock, com `expected_state` (409 manifestation_changed).
module Ombudsman
  module FinalResponse
    FROM = %w[in_analysis forwarded].freeze

    module_function

    # -> Result.ok(manifestation:) | fail(:invalid_request, details: { path: "text" | "resolution", problems: })
    #  | fail(:not_found) | fail(:manifestation_changed) | fail(:invalid_transition) | fail(:forwarding_pending)
    def call(manifestation_id:, expected_state:, text:, resolution:, by:, now: Time.current)
      value = Input.text(text, Catalog::TEXT)
      return Input.refuse("text") unless value
      return Input.refuse("resolution") unless resolution.nil? || Catalog::RESOLUTIONS.include?(resolution)

      ApplicationRecord.transaction do
        manifestation = Lock.manifestation!(manifestation_id)
        next Result.fail(:not_found) unless manifestation

        refusal = Lock.check(manifestation, expected_state)
        next refusal if refusal
        next Result.fail(:invalid_transition) unless FROM.include?(manifestation.state)
        next Result.fail(:forwarding_pending) if manifestation.state == "forwarded" || pending?(manifestation)
        next Input.refuse("resolution") if Catalog::RESOLUTION_KINDS.include?(manifestation.kind) == resolution.nil?

        manifestation.update!(state: "answered", resolution: resolution, concluded_at: now, updated_at: now)
        OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: "final_response", actor: "staff", actor_user: by,
                               text: value, data: resolution ? { "resolution" => resolution } : {},
                               visible_to_citizen: !manifestation.anonymous?, created_at: now)
        DomainEvents.publish("ombudsman.concluded", manifestation_id: manifestation.id, outcome: "answered")
        Notify.call(manifestation: manifestation, kind: "final_response", now: now)
        Result.ok(manifestation: manifestation)
      end
    end

    def pending?(manifestation)
      OmbudsmanForwarding.where(ombudsman_manifestation_id: manifestation.id, state: "pending").exists?
    end

    private_class_method :pending?
  end
end
