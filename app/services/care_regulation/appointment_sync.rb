# Rede própria acompanhada pelo módulo 17 (ADR 0044; contrato §7, §13 G1, G6;
# plano do api, Desvios 7 e 8, Review Focus 2 e 3). Reconcilia o pedido de
# regulação pelo ESTADO ATUAL do pedido de agendamento mais novo da cadeia —
# nunca pelo evento que chegou: a ordem de chegada e o redespacho não
# importam (nunca uma segunda falta por redespacho, nunca regressão de
# `completed`).
#
# Cadeia = o pedido de agendamento do pedido de regulação
# (`appointment_request_id`) e os ligados a ele por `moved_from_request_id`,
# para trás e para a frente (o Drain copia `created_at`: nunca ordenar por
# data). Evento de pedido fora da cadeia (ex.: o no_show redespachado depois
# da falta e da reautorização) → :ignored.
#
# Só com o pedido de regulação em `authorized`/`scheduled`; estado atual do
# pedido de agendamento mais novo (seguindo os `moved`) → situação:
#   scheduled com horário vivo      → scheduled (data e local da unidade)
#   open reaberto por no_show       → falta (Misses) e o pedido de agendamento
#                                     encerrado `dismissed`/SYNC_NOTES[:missed]
#   open (expired, remarque, sem horário) → authorized, sem a data, sem falta
#   closed fulfilled                → completed
#   closed citizen_cancelled | consent_revoked | dismissed (fora de
#     SYNC_NOTES)                   → cancelled, cota liberada, sem autor (R5)
#   closed moved                    → segue para o pedido novo
#
# Rede de segurança (corrida Cancelar × Drain): pedido de regulação já
# encerrado (TERMINAL_STATUSES) com pedido de agendamento regulado vivo dele
# → o vivo é encerrado `dismissed`/SYNC_NOTES[:cancelled], sem mexer na cota
# nem na situação.
#
# Travas (as do Decide): oferta da autorização vigente FOR UPDATE (só quando o
# caminho é liberar a cota; decidido antes numa leitura sem trava e conferido
# sob as travas — divergiu, refaz) → pedido de regulação FOR NO KEY UPDATE
# (não conflita com o FOR KEY SHARE da FK que o Drain pede ao criar o pedido
# novo) → pedidos de agendamento da cadeia (FOR UPDATE), na ordem da cadeia.
# A cota só é liberada por UPDATE em regulation_authorizations.
#
# Roda com o interruptor em qualquer estado (R16, G6): é consistência do que
# já existe. Eventos publicados (pela Transition) só com ids; `by` nulo.
module CareRegulation
  module AppointmentSync
    ACTIVE = %w[authorized scheduled].freeze
    RELEASE_REASON = { "citizen_cancelled" => "citizen_cancelled", "consent_revoked" => "consent_revoked",
                       "dismissed" => "unit_dismissed" }.freeze
    ATTEMPTS = 3

    # A leitura sem trava disse "não libera" e, sob as travas, o caminho é
    # liberar (ou a autorização vigente mudou): refaz com a oferta travada.
    class Stale < StandardError; end

    module_function

    # -> :ignored | :unchanged | String (a situação nova)
    def call(appointment_request_id:, now: Time.current)
      event_request = AppointmentRequest.find_by(id: appointment_request_id)
      return :ignored unless event_request&.kind == "regulated"

      request = RegulationRequest.find_by(id: event_request.origin_regulation_request_id)
      return :ignored unless request

      attempt = 0
      begin
        attempt += 1
        ApplicationRecord.transaction(requires_new: true) { reconcile(request.reload, event_request.id, now) }
      rescue Stale
        retry if attempt < ATTEMPTS
        raise
      end
    end

    def reconcile(request, event_request_id, now)
      seen = releasing_preview?(request) ? vigente(request) : nil
      CareOffer.lock.find(seen.care_offer_id) if seen
      request.lock!(Decide::LOCK)

      if Catalog::TERMINAL_STATUSES.include?(request.status)
        dismiss_orphans!(request)
        return chain_ids(request).include?(event_request_id) ? :unchanged : :ignored
      end
      return :ignored unless ACTIVE.include?(request.status) && request.appointment_request_id

      visited = follow!(request.appointment_request_id)
      return :ignored unless (backward_ids(request.appointment_request_id) | visited.map(&:id)).include?(event_request_id)

      apply!(request, visited.last, seen, now)
    end

    def apply!(request, current, seen, now)
      target, detail = target_for(current)
      case target
      when :scheduled then schedule!(request, current, detail)
      when :authorized then back_to_authorized!(request, current)
      when :missed then miss!(request, current)
      when :completed then transition!(request, "completed", appointment_request_id: current.id)
      when :cancelled then cancel!(request, current, seen, detail, now)
      else point!(request, current)
      end
    end

    # [situação-alvo, detalhe] pelo estado do pedido de agendamento.
    def target_for(current)
      case current.status
      when "scheduled"
        live = current.appointments.live.order(:id).last
        live ? [ :scheduled, live ] : [ :none ]
      when "open" then current.reopened_reason == "no_show" ? [ :missed ] : [ :authorized ]
      else closed_target(current)
      end
    end

    def closed_target(current)
      case current.closed_reason
      when "fulfilled" then [ :completed ]
      when "citizen_cancelled", "consent_revoked" then [ :cancelled, RELEASE_REASON.fetch(current.closed_reason) ]
      when "dismissed"
        # Encerrado pela própria regulação (falta, cancelamento): já refletido.
        Catalog::SYNC_NOTES.value?(current.dismiss_reason) ? [ :none ] : [ :cancelled, RELEASE_REASON.fetch("dismissed") ]
      else [ :none ]
      end
    end

    def schedule!(request, current, appointment)
      place = place_for(appointment.health_unit)
      if request.status == "scheduled" && request.scheduled_at == appointment.scheduled_at && request.schedule_place == place
        return point!(request, current)
      end

      transition!(request, "scheduled", scheduled_at: appointment.scheduled_at, schedule_place: place, schedule_notes: nil,
                                        appointment_request_id: current.id)
    end

    # Horário expirado (sem confirmação), remarque pedido pelo cidadão ou
    # pedido sem horário: volta a authorized, sem a data e sem contar falta.
    def back_to_authorized!(request, current)
      return point!(request, current) if request.status == "authorized" && request.scheduled_at.nil?

      transition!(request, "authorized", scheduled_at: nil, schedule_place: nil, schedule_notes: nil,
                                         appointment_request_id: current.id)
    end

    # A falta e, na MESMA transação, o pedido de agendamento reaberto pelo
    # Lapse encerrado (já travado no follow!, depois do pedido de regulação).
    def miss!(request, current)
      Misses.apply!(request: request, by: nil)
      AppointmentRequests::Lifecycle.close!(current, reason: "dismissed", dismiss_reason: Catalog::SYNC_NOTES.fetch(:missed))
      request.status
    end

    # Encerramento do 17 fora da regulação: cota liberada (só UPDATE na
    # autorização) e cancelled sem autor. A autorização relida sob a trava do
    # pedido precisa ser a que a leitura sem trava viu (e cuja oferta travou).
    def cancel!(request, current, seen, release_reason, now)
      authorization = vigente(request)
      raise Stale if authorization&.id != seen&.id

      authorization&.update!(released_at: now, release_reason: release_reason)
      transition!(request, "cancelled", appointment_request_id: current.id)
    end

    def transition!(request, to, changes)
      transitioned = Transition.call(request: request, to: to, by: nil, changes: changes)
      # Sem versão a conferir: só falha por erro de programação.
      raise ArgumentError, "sincronização recusada: #{transitioned.reason}" unless transitioned.ok?

      to
    end

    # Nada muda na situação; só o ponteiro segue o pedido novo (Drain).
    def point!(request, current)
      request.update!(appointment_request_id: current.id) if request.appointment_request_id != current.id
      :unchanged
    end

    # Rede de segurança: o vivo de um pedido de regulação encerrado.
    def dismiss_orphans!(request)
      AppointmentRequest.live_requests.where(origin_regulation_request_id: request.id).order(:id).lock.each do |orphan|
        AppointmentRequests::Lifecycle.close!(orphan, reason: "dismissed", dismiss_reason: Catalog::SYNC_NOTES.fetch(:cancelled))
      end
    end

    # O pedido de agendamento e, para a frente, os que o Drain criou a partir
    # dele (encerrado como `moved`), travados na ordem da cadeia.
    def follow!(start_id)
      visited = [ AppointmentRequest.lock.find(start_id) ]
      while visited.last.status == "closed" && visited.last.closed_reason == "moved"
        fresh = AppointmentRequest.lock.find_by(moved_from_request_id: visited.last.id)
        break unless fresh

        visited << fresh
      end
      visited
    end

    # A leitura sem trava: o caminho é liberar a cota?
    def releasing_preview?(request)
      return false unless ACTIVE.include?(request.status) && request.appointment_request_id

      current = AppointmentRequest.find(request.appointment_request_id)
      while current.status == "closed" && current.closed_reason == "moved"
        fresh = AppointmentRequest.find_by(moved_from_request_id: current.id)
        break unless fresh

        current = fresh
      end
      target_for(current).first == :cancelled
    end

    def chain_ids(request)
      return [] unless request.appointment_request_id

      ids = backward_ids(request.appointment_request_id)
      current = ids.first
      while (fresh = AppointmentRequest.where(moved_from_request_id: current).pick(:id))
        ids << fresh
        current = fresh
      end
      ids
    end

    # O pedido e os anteriores a ele (moved_from_request_id), sem data.
    def backward_ids(start_id)
      ids = [ start_id ]
      while (previous = AppointmentRequest.where(id: ids.last).pick(:moved_from_request_id))
        ids << previous
      end
      ids
    end

    # A autorização não liberada mais recente, lida do banco.
    def vigente(request)
      RegulationAuthorization.unreleased.where(regulation_request_id: request.id).order(:created_at, :id).last
    end

    # Local da rede própria: nome da unidade e endereço. Só o endereço é
    # cortado para caber em PLACE_MAX; o nome nunca.
    def place_for(unit)
      address = Scheduling::UnitAddress.call(unit).values_at(:street, :number, :complement).compact_blank.join(", ")
      return unit.name if address.empty?

      place = "#{unit.name} — #{address}"
      return place if place.length <= Catalog::PLACE_MAX

      room = Catalog::PLACE_MAX - unit.name.length - " — ".length
      room.positive? ? "#{unit.name} — #{address[0, room].rstrip}" : unit.name
    end
    private_class_method :reconcile, :apply!, :target_for, :closed_target, :schedule!, :back_to_authorized!, :miss!, :cancel!,
                         :transition!, :point!, :dismiss_orphans!, :follow!, :releasing_preview?, :chain_ids, :backward_ids,
                         :vigente, :place_for
  end
end
