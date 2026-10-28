# Devolver, negar e cancelar um pedido de regulação (ADR 0044; contrato §4,
# §13 G1, G7; plano do api, Desvio 9). De onde cada decisão vale:
#   return ← pending; deny ← pending, returned;
#   cancel ← pending, returned, external, authorized, scheduled.
# Motivo em REASON (10–500, sem espaços nas pontas), cifrado no andamento.
#
# Cancelar com autorização vigente (pedido `authorized`/`scheduled`) devolve a
# cota: só um UPDATE em regulation_authorizations (released_at, release_reason
# "cancelled"). Ordem de travas, a do Authorize (oferta → pedido de regulação
# → pedido de agendamento): a oferta da autorização vigente é lida ANTES, pelo
# id, e travada FOR UPDATE; depois o pedido; a autorização relida sob a trava
# do pedido e diferente da lida antes → stale_version. Na rede própria o
# pedido de agendamento vivo (lock!) precisa estar `open` — encerrado como
# `dismissed` com a nota SYNC_NOTES[:cancelled] —; com horário marcado
# (`scheduled`) → appointment_scheduled e nada muda (R4: o 17 não cancela
# horário pela equipe).
#
# Autorização não liberada de um pedido que voltou a `pending` depois da falta
# não é vigente: a falta consome a vaga (Desvio 8) e o cancelamento não a
# devolve.
#
# Motivo nunca em log, evento nem Result de recusa.
module CareRegulation
  module Decide
    RULES = {
      "return" => { to: "returned", from: %w[pending] },
      "deny" => { to: "denied", from: %w[pending returned] },
      "cancel" => { to: "cancelled", from: %w[pending returned external authorized scheduled] }
    }.freeze
    RELEASING = %w[authorized scheduled].freeze
    # FOR NO KEY UPDATE, não FOR UPDATE: o Drain do 17 trava o pedido de
    # agendamento e então cria o novo com origin_regulation_request_id — a FK
    # pede FOR KEY SHARE neste pedido. FOR UPDATE aqui, esperando o pedido de
    # agendamento, fecharia um ciclo com ele; NO KEY UPDATE não conflita com a
    # FK e segue exclusivo entre os comandos da regulação (conflita com o FOR
    # UPDATE do Authorize e consigo mesmo).
    LOCK = "FOR NO KEY UPDATE".freeze

    module_function

    # -> Result.ok(request:) | fail(:invalid_request, details: { path: }) |
    # fail(:stale_version | :invalid_transition | :appointment_scheduled)
    def call(request:, decision:, reason:, version:, by:, now: Time.current)
      rule = RULES.fetch(decision.to_s) { raise ArgumentError, "decisão desconhecida: #{decision}" }
      text = reason.is_a?(String) ? reason.strip : nil
      return invalid("reason") unless text && Catalog::REASON.cover?(text.length)
      return invalid("version") unless version.is_a?(Integer)

      cancel = decision.to_s == "cancel"
      ApplicationRecord.transaction(requires_new: true) do
        seen = cancel ? vigente(request) : nil
        CareOffer.lock.find(seen.care_offer_id) if seen
        request.lock!(LOCK)
        next Result.fail(:stale_version) if version != request.version
        next Result.fail(:invalid_transition) unless rule.fetch(:from).include?(request.status)

        if cancel
          current = vigente(request)
          next Result.fail(:stale_version) if current&.id != seen&.id

          appointment = live_appointment(request)
          next Result.fail(:appointment_scheduled) if appointment&.status == "scheduled"

          if appointment
            AppointmentRequests::Lifecycle.close!(appointment, reason: "dismissed", by: by,
                                                               dismiss_reason: Catalog::SYNC_NOTES.fetch(:cancelled))
          end
          current.update!(released_at: now, release_reason: "cancelled") if current && RELEASING.include?(request.status)
        end

        transitioned = Transition.call(request: request, to: rule.fetch(:to), by: by, reason: text, version: version)
        # A versão já foi conferida sob a trava: só falha por erro de programação.
        raise ArgumentError, "decisão recusada: #{transitioned.reason}" unless transitioned.ok?

        Result.ok(request: request)
      end
    end

    # A autorização não liberada mais recente, lida do banco (nunca do cache da
    # associação).
    def vigente(request)
      RegulationAuthorization.unreleased.where(regulation_request_id: request.id).order(:created_at, :id).last
    end

    # O pedido de agendamento vivo (open/scheduled) do pedido de regulação: o
    # índice único idx_appointment_requests_one_live_regulated garante um só,
    # mesmo depois de um `moved` do 17. Travado depois do pedido de regulação.
    def live_appointment(request)
      AppointmentRequest.live_requests.where(origin_regulation_request_id: request.id).lock.first
    end

    def invalid(path) = Result.fail(:invalid_request, details: { path: path })
    private_class_method :vigente, :live_appointment, :invalid
  end
end
