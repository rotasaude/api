# POST /ombudsman/reopen_requests/:id/decide (ADR 0051; contrato §2; §16 Q8,
# Q32). O ouvidor decide o pedido de reabertura do cidadão, uma vez:
# - `decision` accept | reject (senão 422 path decision); `text` em TEXT
#   (10..4000, sem as bordas) nos dois casos → 422 path text;
# - só `pending` (decidido → 409 already_decided); a trava é a de toda ação
#   (cidadão → manifestação, Ombudsman::Lock) e depois o pedido;
# - `accept` faz a reabertura (Ombudsman::Reopen.apply!) na mesma transação,
#   com o texto no evento `reopened`; `reject` grava o evento visível
#   `reopen_rejected` com o texto, que vai à linha do tempo do cidadão;
# - nos dois, o aviso `reopen_decided` (Ombudsman::Notify, a ÚLTIMA escrita).
module Ombudsman
  module DecideReopen
    DECISIONS = %w[accept reject].freeze

    module_function

    # -> Result.ok(manifestation:, request:) | fail(:invalid_request, details: { path:, problems: })
    #  | fail(:not_found) | fail(:already_decided) | fail(:invalid_transition)
    def call(request_id:, decision:, text:, by:, now: Time.current)
      return Input.refuse("decision") unless DECISIONS.include?(decision)

      value = Input.text(text, Catalog::TEXT)
      return Input.refuse("text") unless value

      ApplicationRecord.transaction do
        manifestation_id = OmbudsmanReopenRequest.where(id: request_id).pick(:ombudsman_manifestation_id)
        next Result.fail(:not_found) unless manifestation_id

        manifestation = Lock.manifestation!(manifestation_id)
        request = manifestation && OmbudsmanReopenRequest.lock("FOR UPDATE").find_by(id: request_id)
        next Result.fail(:not_found) unless request
        next Result.fail(:already_decided) unless request.state == "pending"

        if decision == "accept"
          next Result.fail(:invalid_transition) unless Reopen::FROM.include?(manifestation.state)

          Reopen.apply!(manifestation, text: value, by: by, now: now)
        else
          OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: "reopen_rejected", actor: "staff", actor_user: by,
                                 text: value, data: {}, visible_to_citizen: true, created_at: now)
        end
        request.update!(state: decision == "accept" ? "accepted" : "rejected", decision_text: value, decided_by_user: by,
                        decided_at: now, updated_at: now)
        Notify.call(manifestation: manifestation, kind: "reopen_decided", now: now)
        Result.ok(manifestation: manifestation, request: request)
      end
    end
  end
end
