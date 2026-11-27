module Regulation
  # Recálculo do estado desejado do envio de um pedido de regulação à RNDS
  # (módulo 26c; contrato §2; Q7, Q8; pré-voo B3, I9). Decide O QUE deve ir;
  # quem envia é a Task 12 (`RndsDeliverJob`). Nunca chama a RNDS.
  #
  # Desejado = a situação (`target`), a impressão digital do documento dessa
  # situação (`RiraBundle.digest`, Valor 9) e os passos da falta
  # (`RndsStatus.steps` depois da última remessa aceita). O documento é montado
  # sem credencial (I9): o que vem dela (`identifier`, `Composition.author`)
  # está fora da impressão digital.
  #
  # Situação da linha (fora de `sending`, que é do envio e só tem o desejado
  # atualizado), nesta ordem:
  # - `erased` (Q8): já havia documento aceito e o paciente perdeu CPF e CNS;
  # - `excluded` (Q7, decisão 13): desejado `excluded`, nenhuma remessa sem
  #   resposta depois do último aceite, e (a) nada foi aceito (sem envio) ou
  #   (b) o `excluded` já foi aceito (para); com documento aceito de outra
  #   situação, a substituição `excluded` vai pela fila;
  # - `blocked` (B3): segue até a impressão digital do desejado mudar;
  #   `rejected`/`failed` (B3, fix I3): seguem até o desejado diferir do que
  #   foi recusado (o digest da última remessa);
  # - `queued` quando há remessa sem resposta depois do último aceite (a
  #   reconciliação da Task 12 decide; fix I2), passos, ou o desejado difere
  #   do último aceite (`sent_status`, `sent_digest`); senão `idle`.
  # Entrar em `queued`: `next_attempt_at = now`, `attempts = 0` e o evento
  # `regulation_rnds.queued` (só ids). Desejado mudou → `enqueued_at = now`.
  #
  # Faixa (Q26, `initial_load`): uma mudança de ajuste (`lane: :bulk`, o
  # recálculo em massa) que põe a linha na fila a manda para a faixa da carga
  # inicial (60 por minuto, depois das vivas, carência de 72 h do alarme D-1 a
  # contar do `enqueued_at`); a linha que já estava na fila fica na sua. A
  # mudança do próprio pedido (`lane: :live`) a devolve à faixa normal. Sem
  # `lane` (o envio relendo o desejado), a faixa não muda.
  module RndsSync
    EXCLUDED = "excluded".freeze
    REFUSED = %w[rejected failed].freeze
    SENDING = "sending".freeze
    # Só os eventos de um pedido vivo criam linha (com o interruptor ligado);
    # oferta, prestador, unidade e ajustes só recalculam as que existem (a
    # carga inicial cuida do resto, e um terminal antigo nunca nasce aqui).
    CREATING_EVENT = /\A(regulation_request|appointment|appointment_request)\./

    module_function

    # -> RegulationRndsSync | nil (sem linha e sem criar, rascunho, ou
    # `excluded` sem linha).
    def recompute!(request, create:, now:, initial_load: false, lane: nil, settings: RegulationRndsSetting.current)
      RegulationRndsSync.transaction(requires_new: true) do
        sync = RegulationRndsSync.lock.find_by(regulation_request_id: request.id)
        next sync if sync.nil? && !create

        target = target(request, settings: settings)
        next sync if target == :none
        next nil if sync.nil? && target.status == EXCLUDED

        sync ||= RegulationRndsSync.new(regulation_request: request, initial_load: initial_load, enqueued_at: now)
        apply!(sync, request, target, settings, now, lane)
      end
    end

    # A situação desejada: RndsStatus::Target | :none. O `excluded` ganha o
    # instante (o documento precisa de `event.period.end`), estável e só do
    # pedido (fix I1: gravar os ajustes não o move): o mais recente entre a
    # última linha do andamento e o `requested_at`.
    def target(request, settings:)
      found = RndsStatus.for(request, settings: settings)
      return found unless found == :excluded

      RndsStatus::Target.new(status: EXCLUDED, at: [ request.events.map(&:created_at).max, request.requested_at ].compact.max)
    end

    # Há remessa de documento que saiu depois do último aceite (ou desde
    # sempre, sem aceite) e não teve resposta (timeout; Review Focus 1, fix
    # I2): não se sabe se a RNDS a gravou. O sinal da reconciliação é este,
    # não o `attempts`. O predicado é o RegulationRndsDelivery.unanswered_for
    # (a remessa `delete` não conta; a fechada pela reconciliação, Q25, também não).
    def unanswered_delivery?(sync)
      return false if sync.new_record?

      RegulationRndsDelivery.unanswered_for(sync).exists?
    end

    # -> [id do pedido] | :all
    def affected_request_ids(event_name, payload)
      payload = payload.to_h.symbolize_keys
      case event_name
      when /\Aregulation_request\./ then [ payload[:regulation_request_id] ].compact
      when "care_offer.changed" then by_offers(payload[:care_offer_id])
      when "care_provider.changed" then by_providers(payload[:care_provider_id])
      when "health_unit.changed" then by_unit(payload[:health_unit_id])
      # Q27: o care_regulation.settings_changed (prazos, lista do enfermeiro) não é gatilho.
      when "regulation_rnds.settings_changed" then :all
      else
        resolver = CareRegulation::AppointmentSyncJob::RESOLVERS.fetch(event_name) { raise ArgumentError, "evento não consumido: #{event_name}" }
        id = resolver.call(payload)
        return [] if id.blank?

        AppointmentRequest.where(id: id).where.not(origin_regulation_request_id: nil).pluck(:origin_regulation_request_id)
      end
    end

    # Os pedidos que um recálculo por ajuste olha, dentro de `scope` (Q26 b):
    # fora os terminais cujo último aceite tem mais de INITIAL_LOAD_DAYS dias
    # (o que nunca foi aceito segue: ainda não chegou à RNDS).
    def bulk_requests(scope, now:)
      stale = RegulationRndsSync.where(last_accepted_at: ...(now - RndsLimits::INITIAL_LOAD_DAYS.days)).select(:regulation_request_id)
      scope.where.not(id: RegulationRequest.where(status: CareRegulation::Catalog::TERMINAL_STATUSES, id: stale).select(:id))
    end

    # Os regulados pelo estado não terminais (fora do rascunho) ainda sem linha.
    def uncovered_state_regulated
      RegulationRequest.where(state_regulated: true).where.not(status: [ "draft", *CareRegulation::Catalog::TERMINAL_STATUSES ])
                       .where.not(id: RegulationRndsSync.select(:regulation_request_id))
    end

    def apply!(sync, request, target, settings, now, lane)
      facts = RiraFacts.for(request: request, settings: settings, credential: nil)
      excluded = target.status == EXCLUDED
      erased = erased?(sync, facts)
      steps = excluded || erased ? [] : RndsStatus.steps(request, since: accepted_since(sync), settings: settings)
      digest = RiraBundle.digest(RiraBundle.build(facts: facts, sync: sync, status: target, now: now))
      digest_changed = sync.desired_digest != digest
      refused_digest = last_delivery_digest(sync)
      # O próximo documento a sair (o primeiro passo, senão o desejado): é ele
      # que se compara com o recusado (Task 12, carry 7: o passo recusado).
      next_digest = steps.any? ? RiraBundle.digest(RiraBundle.build(facts: facts, sync: sync, status: steps.first, now: now)) : digest
      changed = [ sync.desired_status, sync.desired_digest, sync.pending_steps ] != [ target.status, digest, steps ]
      sync.assign_attributes(desired_status: target.status, desired_digest: digest, pending_steps: steps)

      was = sync.status
      queued = false
      unless was == SENDING
        status = next_status(sync, was, erased: erased, digest_changed: digest_changed, refused_digest: refused_digest,
                                         next_digest: next_digest)
        sync.enqueued_at = now if changed
        queued = status == "queued" && was != "queued"
        sync.initial_load = lane_of(sync, lane, changed: changed, queued: queued)
        sync.assign_attributes(next_attempt_at: now, attempts: 0) if queued
        sync.next_attempt_at = nil if %w[idle excluded erased].include?(status)
        sync.blocked_reasons = [] unless status == "blocked"
        sync.status = status
      end
      sync.save!
      if queued
        DomainEvents.publish(
          "regulation_rnds.queued",
          regulation_rnds_sync_id: sync.id, regulation_request_id: request.id
        )
      end
      sync
    end

    # A situação da linha com o desejado já gravado: `erased`, depois as regras
    # de repouso (`resting_status`, as mesmas do envio) quando não há remessa
    # sem resposta, com o `blocked` e o `rejected`/`failed` mantidos até o
    # conteúdo mudar; o resto vai à fila.
    def next_status(sync, was, erased:, digest_changed:, refused_digest:, next_digest:)
      return "erased" if erased

      resting = unanswered_delivery?(sync) ? nil : resting_status(sync, erased: false)
      return EXCLUDED if resting == EXCLUDED
      return was if was == "blocked" && !digest_changed
      # rejected/failed: só com outro conteúdo do que foi recusado — o próximo
      # documento (passo ou desejado) contra a última remessa; sem remessa, o
      # desejado anterior.
      return was if REFUSED.include?(was) && (refused_digest ? next_digest == refused_digest : !digest_changed)

      resting || "queued"
    end

    # Q8: já havia documento aceito e o paciente perdeu CPF e CNS.
    def erased?(sync, facts) = sync.last_rnds_id.present? && facts.patient_cpf.blank? && facts.patient_cns.blank?

    # A situação de repouso de uma linha que não espera resposta, a regra única
    # do recálculo e do envio (RndsDelivery): `erased`; `excluded` quando o
    # desejado é `excluded` e nada foi aceito ou o `excluded` já foi aceito
    # (com outro documento aceito, a substituição vai: nil); nil com passos ou
    # com o desejado diferente do último aceite; senão `idle`.
    def resting_status(sync, erased:)
      return "erased" if erased
      if sync.desired_status == EXCLUDED
        return sync.last_rnds_id.nil? || sync.sent_status == EXCLUDED ? EXCLUDED : nil
      end
      return nil if sync.pending_steps.any?
      return nil if sync.desired_status.present? && [ sync.desired_status, sync.desired_digest ] != [ sync.sent_status, sync.sent_digest ]

      "idle"
    end

    # A faixa da linha depois do recálculo (Q26).
    def lane_of(sync, lane, changed:, queued:)
      return false if lane == :live && changed
      return true if lane == :bulk && changed && queued

      sync.initial_load
    end

    # O digest da última remessa de documento (a recusada ou falha).
    def last_delivery_digest(sync)
      return nil if sync.new_record?

      RegulationRndsDelivery.where(regulation_rnds_sync_id: sync.id, kind: RegulationRndsDelivery::DOCUMENT_KINDS).order(:sent_at, :id).last&.digest
    end

    # O `sent_at` da última remessa aceita (nil = nenhuma: todos os passos).
    def accepted_since(sync)
      return nil if sync.new_record?

      RegulationRndsDelivery.accepted_since(sync)
    end

    def by_offers(offer_ids)
      RegulationAuthorization.where(care_offer_id: offer_ids).distinct.pluck(:regulation_request_id)
    end

    def by_providers(provider_ids)
      by_offers(CareOffer.where(care_provider_id: provider_ids).select(:id)) |
        RegulationRequest.where(care_provider_id: provider_ids).pluck(:id)
    end

    def by_unit(unit_id)
      return [] if unit_id.blank?

      RegulationRequest.where(requester_unit_id: unit_id).pluck(:id) |
        by_providers(CareProvider.where(kind: "own", health_unit_id: unit_id).select(:id)) |
        Appointment.joins(:request).where(health_unit_id: unit_id).where.not(appointment_requests: { origin_regulation_request_id: nil })
                   .distinct.pluck("appointment_requests.origin_regulation_request_id")
    end

    private_class_method :apply!, :lane_of, :next_status, :last_delivery_digest, :accepted_since, :by_offers, :by_providers, :by_unit
  end
end
