# Rede própria acompanhada pelo módulo 17 (ADR 0044; contrato §7, §13 G1, G6;
# plano do api, Desvios 7 e 8, Review Focus 2 e 3). Reconcilia o pedido de
# regulação pelo ESTADO ATUAL da cadeia de pedidos de agendamento — nunca pelo
# evento que chegou: a ordem de chegada e o redespacho não importam (nunca uma
# segunda falta por redespacho, nunca regressão de `completed`).
#
# Cadeia = o pedido de agendamento do pedido de regulação
# (`appointment_request_id`) e os ligados a ele por `moved_from_request_id`,
# para trás e para a frente (o Drain copia `created_at`: nunca ordenar por
# data). Cada autorização abre uma cadeia nova: a cadeia é a da autorização
# vigente. Evento de pedido fora da cadeia (ex.: o no_show redespachado depois
# da falta e da reautorização) → :ignored.
#
# Falta (Ruling do controlador, fix round 1): conta quando a cadeia tem um
# horário `no_show` ainda não contado — horários no_show da cadeia menos as
# linhas `missed` do andamento gravadas desde a autorização vigente (a linha é
# a marca; idempotente sem coluna nova). Assim a falta não se perde se a
# recepção remarcar ou a unidade dispensar o pedido reaberto antes do job.
#
# Só com o pedido de regulação em `authorized`/`scheduled`; pelo pedido de
# agendamento mais novo da cadeia (seguindo os `moved`):
#   scheduled com horário vivo      → scheduled (data e local da unidade); com
#                                     falta não contada, ela conta junto
#                                     (remarcado antes do job; na segunda,
#                                     closed — o horário vivo fica com o 17)
#   open com falta não contada      → falta (Misses.apply!) e o pedido de
#                                     agendamento encerrado `dismissed`/
#                                     SYNC_NOTES[:missed] na mesma transação
#   open sem falta (expired, remarque, sem horário) → authorized, sem a data
#   closed fulfilled                → completed (com a falta não contada junto)
#   closed citizen_cancelled | consent_revoked → cancelled, sem autor (R5; a
#                                     falta não contada junto)
#   closed dismissed fora de SYNC_NOTES → falta, se houver não contada (a vaga
#                                     não volta); senão cancelled
#   Cota no cancelled (Ruling, fix round 2): liberada só se a autorização
#   vigente não teve falta (nem contada antes, nem contada agora) — a falta
#   consome a vaga (Desvio 3), então o resultado não depende de o job rodar
#   antes ou depois da remarcação.
#   closed moved                    → segue para o pedido novo
#
# Rede de segurança (corrida Cancelar × Drain): pedido de regulação já
# encerrado (TERMINAL_STATUSES) com pedido de agendamento regulado vivo e
# `open` dele → encerrado `dismissed`/SYNC_NOTES[:cancelled], sem mexer na
# cota nem na situação. O `scheduled` (com horário vivo) fica: só o 17 encerra
# horário (R4), e fechar o pedido com o horário vivo quebraria o check-in.
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

    # O que a cadeia diz: ids (para trás e para a frente), o pedido mais novo,
    # a situação-alvo (com detalhe), as faltas ainda não contadas e se o
    # caminho libera a cota (cancelled sem falta nenhuma da autorização vigente).
    Plan = Struct.new(:chain_ids, :current, :target, :detail, :uncounted, :release, keyword_init: true)

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
        return :unchanged if dismiss_orphans!(request).positive? || chain_ids(request).include?(event_request_id)

        return :ignored
      end
      return :ignored unless ACTIVE.include?(request.status) && request.appointment_request_id

      plan = plan(request, lock: true)
      return :ignored unless plan.chain_ids.include?(event_request_id)

      apply!(request, plan, seen, now)
    end

    def apply!(request, plan, seen, now)
      current = plan.current
      case plan.target
      when :scheduled then schedule!(request, plan)
      when :authorized then back_to_authorized!(request, current)
      when :missed then miss!(request, plan)
      when :completed then transition!(request, "completed", plan, appointment_request_id: current.id)
      when :cancelled then cancel!(request, plan, seen, now)
      else point!(request, current)
      end
    end

    # A cadeia lida (lock: true trava os pedidos de agendamento, na ordem).
    def plan(request, lock:)
      forward = walk(request.appointment_request_id, lock: lock)
      ids = backward_ids(request.appointment_request_id) | forward.map(&:id)
      authorization = vigente(request)
      counted = authorization ? counted_misses(request, authorization) : 0
      uncounted = uncounted_misses(ids, counted)
      target, detail = target_for(forward.last, missed: uncounted.positive?)
      release = target == :cancelled && authorization.present? && counted.zero? && uncounted.zero?
      Plan.new(chain_ids: ids, current: forward.last, target: target, detail: detail, uncounted: uncounted, release: release)
    end

    # [situação-alvo, detalhe] pelo estado do pedido de agendamento mais novo.
    def target_for(current, missed:)
      case current.status
      when "scheduled"
        live = current.appointments.live.order(:id).last
        live ? [ :scheduled, live ] : [ :none ]
      when "open" then missed ? [ :missed ] : [ :authorized ]
      else closed_target(current, missed: missed)
      end
    end

    def closed_target(current, missed:)
      case current.closed_reason
      when "fulfilled" then [ :completed ]
      when "citizen_cancelled", "consent_revoked" then [ :cancelled, RELEASE_REASON.fetch(current.closed_reason) ]
      when "dismissed"
        # Encerrado pela própria regulação (falta, cancelamento): já refletido.
        return [ :none ] if Catalog::SYNC_NOTES.value?(current.dismiss_reason)

        missed ? [ :missed ] : [ :cancelled, RELEASE_REASON.fetch("dismissed") ]
      else [ :none ]
      end
    end

    # Horários no_show da cadeia menos as faltas já contadas desde a
    # autorização vigente (as linhas `missed` gravadas depois dela).
    def uncounted_misses(chain_ids, counted)
      no_shows = Appointment.where(request_id: chain_ids, status: "no_show").count
      [ no_shows - counted, 0 ].max
    end

    def counted_misses(request, authorization)
      RegulationRequestEvent.where(regulation_request_id: request.id, status: "missed")
                            .where(created_at: authorization.created_at..).count
    end

    def schedule!(request, plan)
      appointment = plan.detail
      place = place_for(appointment.health_unit)
      if plan.uncounted.zero? && request.status == "scheduled" && request.scheduled_at == appointment.scheduled_at &&
         request.schedule_place == place
        return point!(request, plan.current)
      end

      # Falta remarcada antes do job que chega à segunda: encerra como o
      # Misses.apply! (sem data nem ponteiro); o horário vivo fica com o 17
      # (R4) e, se o pedido dele reabrir, a rede de segurança o encerra.
      if request.misses + plan.uncounted >= Catalog::MAX_MISSES
        return transition!(request, "closed", plan, scheduled_at: nil, schedule_place: nil, schedule_notes: nil,
                                                    appointment_request_id: nil)
      end

      transition!(request, "scheduled", plan, scheduled_at: appointment.scheduled_at, schedule_place: place,
                                              schedule_notes: nil, appointment_request_id: plan.current.id)
    end

    # Horário expirado (sem confirmação), remarque pedido pelo cidadão ou
    # pedido sem horário: volta a authorized, sem a data e sem contar falta.
    def back_to_authorized!(request, current)
      return point!(request, current) if request.status == "authorized" && request.scheduled_at.nil?

      transition!(request, "authorized", nil, scheduled_at: nil, schedule_place: nil, schedule_notes: nil,
                                              appointment_request_id: current.id)
    end

    # A falta e, na MESMA transação, o pedido de agendamento reaberto pelo
    # Lapse encerrado (já travado no walk, depois do pedido de regulação). O
    # dispensado pela unidade já está encerrado.
    def miss!(request, plan)
      Misses.apply!(request: request, by: nil, count: plan.uncounted)
      if plan.current.status == "open"
        AppointmentRequests::Lifecycle.close!(plan.current, reason: "dismissed", dismiss_reason: Catalog::SYNC_NOTES.fetch(:missed))
      end
      request.status
    end

    # Encerramento do 17 fora da regulação: cancelled sem autor; a cota é
    # liberada (só UPDATE na autorização) quando a autorização vigente não teve
    # falta. Liberando, a autorização relida sob a trava do pedido precisa ser
    # a que a leitura sem trava viu (e cuja oferta travou).
    def cancel!(request, plan, seen, now)
      if plan.release
        authorization = vigente(request)
        raise Stale if authorization.id != seen&.id

        authorization.update!(released_at: now, release_reason: plan.detail)
      end
      transition!(request, "cancelled", plan, appointment_request_id: plan.current.id)
    end

    # A falta ainda não contada (se houver) entra antes, no andamento, e o
    # `misses` vai nas mudanças da mesma transição.
    def transition!(request, to, plan, changes)
      changes = changes.merge(misses: Misses.record!(request: request, by: nil, count: plan.uncounted)) if plan&.uncounted&.positive?
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

    # Rede de segurança: o vivo `open` de um pedido de regulação encerrado.
    # -> quantos encerrou.
    def dismiss_orphans!(request)
      orphans = AppointmentRequest.where(status: "open", origin_regulation_request_id: request.id).order(:id).lock.to_a
      orphans.each do |orphan|
        AppointmentRequests::Lifecycle.close!(orphan, reason: "dismissed", dismiss_reason: Catalog::SYNC_NOTES.fetch(:cancelled))
      end
      orphans.size
    end

    # O caminhador da cadeia para a frente: o pedido de agendamento e os que o
    # Drain criou a partir dele (encerrado como `moved`). lock: true trava cada
    # um (FOR UPDATE), na ordem da cadeia.
    def walk(start_id, lock: false)
      scope = lock ? AppointmentRequest.lock : AppointmentRequest.all
      visited = [ scope.find(start_id) ]
      while visited.last.status == "closed" && visited.last.closed_reason == "moved"
        fresh = scope.find_by(moved_from_request_id: visited.last.id)
        break unless fresh

        visited << fresh
      end
      visited
    end

    # A leitura sem trava: o caminho é liberar a cota?
    def releasing_preview?(request)
      return false unless ACTIVE.include?(request.status) && request.appointment_request_id

      plan(request, lock: false).release
    end

    def chain_ids(request)
      return [] unless request.appointment_request_id

      backward_ids(request.appointment_request_id) | walk(request.appointment_request_id).map(&:id)
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
    private_class_method :reconcile, :apply!, :plan, :target_for, :closed_target, :uncounted_misses, :counted_misses,
                         :schedule!, :back_to_authorized!, :miss!, :cancel!, :transition!, :point!, :dismiss_orphans!,
                         :walk, :releasing_preview?, :chain_ids, :backward_ids, :vigente, :place_for
  end
end
