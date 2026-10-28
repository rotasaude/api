# Autorizar um pedido de regulação numa oferta (ADR 0044; contrato §4, §13 G1,
# G3, G5, G7; plano do api, Desvios 3–6). Só de `pending` não regulado pelo
# estado. Ordem (e de travas — oferta → pedido de regulação → unidade → pares
# → criação; a cota é contada SOB a trava da oferta, então duas autorizações
# na última vaga dão uma autorização e um quota_exhausted):
#
#   1. a entrada (cor da lista, motivos em REASON, versão inteira, oferta uuid);
#   2. CareOffer FOR UPDATE → request.lock!;
#   3. versão (stale_version) e situação (invalid_transition);
#   4. oferta autorizável (Desvio 3): mês corrente no fuso da cidade, prestador
#      ativo (`own`: unidade ativa, FOR SHARE), mesmo alvo — senão invalid_offer;
#   5. cor resultante: mudou a cor efetiva sem motivo → color_reason_required;
#   6. motivo de pular (Desvio 4): outro `pending` do mesmo alvo, mais antigo,
#      de cor efetiva igual ou mais grave que a resultante, sem skip_reason →
#      skip_reason_required, SEM detalhe nenhum dos outros pedidos (G5);
#      motivo (de pular ou da cor) enviado sem necessidade é ignorado;
#   7. cota (Quota.used < quantity) → quota_exhausted;
#   8. RegulationAuthorization (month = mês da oferta) → OwnNetwork.open! se
#      `own` (sem par validado: citizen_not_verified, tudo desfeito) →
#      Transition para `authorized` (color, color_reason, due_on recalculado só
#      se a cor efetiva mudou, appointment_request_id).
#
# Motivos, cor e alvo nunca em log, evento nem Result de recusa.
module CareRegulation
  module Authorize
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    # -> Result.ok(request:, authorization:, appointment_request:) |
    # fail(:invalid_request, details: { path: }) | fail(:invalid_offer |
    # :stale_version | :invalid_transition | :color_reason_required |
    # :skip_reason_required | :quota_exhausted | :citizen_not_verified)
    def call(request:, offer_id:, version:, by:, color: nil, color_reason: nil, skip_reason: nil, now: Time.current)
      return invalid("offer_id") unless offer_id.is_a?(String) && offer_id.match?(UUID)
      return invalid("version") unless version.is_a?(Integer)
      return invalid("color") unless color.nil? || Catalog::COLORS.include?(color)

      color_reason = reason(color_reason)
      return invalid("color_reason") if color_reason == :invalid

      skip_reason = reason(skip_reason)
      return invalid("skip_reason") if skip_reason == :invalid

      today = now.in_time_zone.to_date
      ApplicationRecord.transaction(requires_new: true) do
        offer = CareOffer.lock.find_by(id: offer_id)
        request.lock!
        next Result.fail(:stale_version) if version != request.version
        next Result.fail(:invalid_transition) unless request.status == "pending" && !request.state_regulated
        next Result.fail(:invalid_offer) unless offer && authorizable?(offer, request, today)

        current = request.effective_color
        resulting = color || current
        changed = resulting != current
        next Result.fail(:color_reason_required) if changed && color_reason.nil?

        # Motivo enviado sem necessidade é ignorado (nem gravado nem devolvido):
        # o mais antigo pode ter sido autorizado por outro regulador entre o
        # 422 e o reenvio, e o registro não pode dizer "fora da ordem" sem ter
        # sido; cor confirmada igual à efetiva não tem motivo de mudança.
        color_reason = nil unless changed
        ahead = ahead?(request, resulting)
        next Result.fail(:skip_reason_required) if ahead && skip_reason.nil?

        skip_reason = nil unless ahead

        used = Quota.used([ offer.id ]).fetch(offer.id)
        next Result.fail(:quota_exhausted) unless used < offer.quantity

        authorization = RegulationAuthorization.create!(regulation_request: request, care_offer: offer, month: offer.month,
                                                        authorized_by_user: by, skip_reason: skip_reason)
        changes = {}
        changes[:color] = color if color
        changes[:color_reason] = color_reason if color_reason
        changes[:due_on] = Deadlines.due_on(requested_at: request.requested_at, color: resulting) if changed
        request.assign_attributes(changes)
        appointment = OwnNetwork.open!(request: request, offer: offer, by: by) if offer.care_provider.kind == "own"
        changes[:appointment_request_id] = appointment.id if appointment

        transitioned = Transition.call(request: request, to: "authorized", by: by, version: version, changes: changes)
        # A versão já foi conferida sob a trava: só falha por erro de programação.
        raise ArgumentError, "autorização recusada: #{transitioned.reason}" unless transitioned.ok?

        Result.ok(request: request, authorization: authorization, appointment_request: appointment)
      end
    rescue OwnNetwork::NotVerified
      request.reload
      Result.fail(:citizen_not_verified)
    end

    # Desvio 3 (G1, R10): a oferta do mês corrente no fuso da cidade, de
    # prestador ativo (o próprio, com a unidade ativa: FOR SHARE, depois do
    # pedido na ordem de travas), do mesmo alvo.
    def authorizable?(offer, request, today)
      provider = offer.care_provider
      return false unless offer.month == today.beginning_of_month && provider.active
      return false unless offer.target_type == request.target_type && offer.target_code == request.target_code
      return true unless provider.kind == "own"

      HealthUnit.lock_active!(provider.health_unit_id)
      true
    rescue HealthUnit::Inactive
      false
    end

    # Desvio 4: há outro `pending` (não regulado pelo estado) do mesmo alvo,
    # mais antigo (requested_at menor, ou igual com id menor), de cor efetiva
    # igual ou mais grave que a resultante? `returned` e `external` não estão
    # na fila e não contam.
    def ahead?(request, resulting)
      RegulationRequest.where(status: "pending", state_regulated: false, target_type: request.target_type,
                              target_code: request.target_code)
                       .where.not(id: request.id)
                       .where("regulation_requests.requested_at < :at OR (regulation_requests.requested_at = :at AND regulation_requests.id < :id)",
                              at: request.requested_at, id: request.id)
                       .where("#{Queue::RANK_SQL} <= ?", Catalog::COLOR_RANK.fetch(resulting))
                       .exists?
    end

    # nil (ausente) | texto sem espaços nas pontas em REASON | :invalid.
    def reason(value)
      return nil if value.nil?
      return :invalid unless value.is_a?(String)

      text = value.strip
      Catalog::REASON.cover?(text.length) ? text : :invalid
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
    private_class_method :authorizable?, :ahead?, :reason, :invalid
  end
end
