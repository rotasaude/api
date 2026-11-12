# Regras comuns dos encaminhamentos (ADR 0051; contrato §2, §6; §16 Q33):
# quem é o respondente de um encaminhamento, o que entra no inbox dele, a
# volta da manifestação a `in_analysis` quando não sobra `pending`, e o
# esqueleto das ações do respondente (trava manifestação → encaminhamento,
# destino dele, `expected_state` do encaminhamento).
module Ombudsman
  module Forwardings
    module_function

    # Os encaminhamentos dos destinos em que o usuário é respondente ativo
    # (Access.destinations: linha ativa e o papel ombudsman_responder).
    def inbox_scope(user)
      destinations = Access.destinations(user)
      OmbudsmanForwarding.where(department_id: destinations[:department_ids])
                         .or(OmbudsmanForwarding.where(health_unit_id: destinations[:health_unit_ids]))
    end

    def responder_of?(forwarding, user)
      destinations = Access.destinations(user)
      if forwarding.department_id
        destinations[:department_ids].include?(forwarding.department_id)
      else
        destinations[:health_unit_ids].include?(forwarding.health_unit_id)
      end
    end

    # Resolvido o último `pending`, a manifestação volta a `in_analysis`
    # (contrato §2). Chamado sob a trava da manifestação.
    def settle!(manifestation, now:)
      return unless manifestation.state == "forwarded"
      return if OmbudsmanForwarding.where(ombudsman_manifestation_id: manifestation.id, state: "pending").exists?

      manifestation.update!(state: "in_analysis", updated_at: now)
    end

    # Ação do respondente: na transação, trava a manifestação e o
    # encaminhamento (Lock.forwarding!); encaminhamento de outro destino ou
    # inexistente → not_found; `expected_state` do encaminhamento
    # (Lock.check_forwarding); então o bloco (manifestação, encaminhamento).
    def as_responder(forwarding_id:, expected_state:, by:)
      ApplicationRecord.transaction do
        locked = Lock.forwarding!(forwarding_id)
        next Result.fail(:not_found) unless locked && responder_of?(locked.last, by)

        refusal = Lock.check_forwarding(locked.last, expected_state)
        next refusal if refusal

        yield(*locked)
      end
    end

    # O evento da linha do tempo de uma ação sobre o encaminhamento: da
    # equipe (o técnico ou o respondente), nunca visível ao cidadão, só o id.
    def event!(manifestation, forwarding, kind, by:, now:, text: nil)
      OmbudsmanEvent.create!(ombudsman_manifestation: manifestation, kind: kind, actor: "staff", actor_user: by, text: text,
                             data: { "forwarding_id" => forwarding.id }, visible_to_citizen: false, created_at: now)
    end
  end
end
