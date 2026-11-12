# POST /ombudsman/manifestations/:id/archive (ADR 0051; contrato §2; §16 Q8,
# Q26, Q32, Q36). O ouvidor arquiva uma manifestação aberta que ainda não foi
# a um respondente — `received`, `in_analysis` ou `awaiting_complement` (as
# outras → 422 invalid_transition; uma `forwarded` espera os encaminhamentos):
# - `reason` em ARCHIVE_REASONS (senão 422 path reason);
# - `duplicate` exige OUTRA manifestação, por `duplicate_of_id` (a tela pode
#   mandar o protocolo; o controlador o resolve em id — Q26) → 422 path
#   duplicate_of_id; qualquer outro motivo não leva `duplicate_of_id`;
# - `forwarded_elsewhere` exige `external_body_name` (1..120, sem as bordas) →
#   422 path external_body_name; qualquer outro motivo não o leva;
# - `no_complement` é só do job diário (Task 17): ele chama o comando direto,
#   com `actor: "system"` e `by: nil`; a recusa para a equipe (Q36) está no
#   controlador.
# Grava `concluded_at = now`, evento `archived` (visível, `data: { reason }`),
# ombudsman.concluded { manifestation_id, outcome: "archived" } e o aviso
# `archived` (Ombudsman::Notify, a ÚLTIMA escrita — F-24). Sob
# Ombudsman::Lock, com `expected_state` (409 manifestation_changed).
module Ombudsman
  module Archive
    FROM = %w[received in_analysis awaiting_complement].freeze
    ACTORS = %w[staff system].freeze

    module_function

    # -> Result.ok(manifestation:) | fail(:invalid_request, details: { path:, problems: })
    #  | fail(:not_found) | fail(:manifestation_changed) | fail(:invalid_transition)
    def call(manifestation_id:, expected_state:, reason:, duplicate_of_id:, external_body_name:, by:, actor: "staff", now: Time.current)
      raise ArgumentError, "actor" unless ACTORS.include?(actor)
      return Input.refuse("reason") unless Catalog::ARCHIVE_REASONS.include?(reason)

      duplicate = reason == "duplicate"
      return Input.refuse("duplicate_of_id") unless duplicate ? uuid?(duplicate_of_id) : duplicate_of_id.nil?

      elsewhere = reason == "forwarded_elsewhere"
      body_name = external_body_name.is_a?(String) ? external_body_name.strip : nil
      return Input.refuse("external_body_name") unless elsewhere ? (body_name && (1..Catalog::EXTERNAL_BODY_MAX).cover?(body_name.length)) : external_body_name.nil?

      ApplicationRecord.transaction do
        manifestation = Lock.manifestation!(manifestation_id)
        next Result.fail(:not_found) unless manifestation

        refusal = Lock.check(manifestation, expected_state)
        next refusal if refusal
        next Result.fail(:invalid_transition) unless FROM.include?(manifestation.state)

        original_id = duplicate_of_id&.downcase
        next Input.refuse("duplicate_of_id") if duplicate && (original_id == manifestation.id || !OmbudsmanManifestation.exists?(id: original_id))

        manifestation.update!(state: "archived", archive_reason: reason, duplicate_of_id: (original_id if duplicate),
                              external_body_name: (body_name if elsewhere), concluded_at: now, updated_at: now)
        OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: "archived", actor: actor, actor_user: by,
                               text: nil, data: { "reason" => reason }, visible_to_citizen: true, created_at: now)
        DomainEvents.publish("ombudsman.concluded", manifestation_id: manifestation.id, outcome: "archived")
        Notify.call(manifestation: manifestation, kind: "archived", now: now)
        Result.ok(manifestation: manifestation)
      end
    end

    def uuid?(value) = value.is_a?(String) && value.match?(BaseController::UUID)

    private_class_method :uuid?
  end
end
