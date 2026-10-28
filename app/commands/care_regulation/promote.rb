# Os rascunhos de regulação valem na finalização e no adendo (ADR 0044;
# contrato §3, §13 G4, G10, G12 #3–#5; plano do api, Desvio 1). Roda DENTRO da
# transação do chamador (Consultations::Finalize / AddAddendum, que já
# travaram a consulta e leram o interruptor fora do savepoint) e trava os
# `draft` da consulta em ordem (created_at, id).
#
# Cada rascunho é revalidado como no SaveDraft, na data de hoje e pelo CBO
# ATUAL da consulta (a designação a outro profissional muda o CBO; a lista do
# enfermeiro pode ter mudado): Targets.resolve → Requesters.check →
# Diagnosis.check. O que não vale mais NUNCA recusa (G4): fica intocado em
# `draft` (mesma versão, sem andamento, sem evento) e volta em `not_sent` com
# o índice na ordem acima, o id, o motivo e o path — nunca alvo, diagnóstico
# nem justificativa. O que vale vira `pending` (ou `external` com
# state_regulated), com o evento `regulation_request.created` (só ids).
module CareRegulation
  module Promote
    module_function

    # -> Result.ok(count:, not_sent: [ { index:, id:, error:, path: } ])
    def call(consultation:, by:, addendum: nil, now: Time.current)
      drafts = RegulationRequest.where(consultation_id: consultation.id, status: "draft").order(:created_at, :id).lock.to_a
      count = 0
      not_sent = []
      drafts.each_with_index do |draft, index|
        target = revalidate(draft, consultation, now)
        if target.is_a?(Result)
          not_sent << { index: index, id: draft.id, error: target.reason.to_s, path: target.details[:path] }.compact
          next
        end

        promote!(draft, target, consultation, by, addendum, now)
        count += 1
      end
      Result.ok(count: count, not_sent: not_sent)
    end

    # -> Target | Result (recusa, com path).
    def revalidate(draft, consultation, now)
      resolved = Targets.resolve(type: draft.target_type, code: draft.target_code, on: now.in_time_zone.to_date)
      return resolved if resolved.failure?

      target = resolved.payload.fetch(:target)
      cbo = consultation.cbo_code
      unless Requesters.check(cbo: cbo, target: target) == :ok
        return Result.fail(:cbo_not_allowed, details: { path: "target_code" })
      end

      diagnosis = Diagnosis.check(cbo: cbo, cid10: draft.cid10, ciap2: draft.ciap2)
      diagnosis.failure? ? diagnosis : target
    end

    def promote!(draft, target, consultation, by, addendum, now)
      to = draft.state_regulated ? "external" : "pending"
      changes = { requested_at: now, due_on: Deadlines.due_on(requested_at: now, color: draft.suggested_color),
                  target_name: target.name, requester_user_id: by.id, requester_cbo: consultation.cbo_code,
                  addendum_id: addendum&.id }
      Transition.call(request: draft, to: to, by: by, changes: changes, event: "created")
    end
    private_class_method :revalidate, :promote!
  end
end
