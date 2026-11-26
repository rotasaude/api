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
    def recompute!(request, create:, now:, initial_load: false, settings: RegulationRndsSetting.current)
      RegulationRndsSync.transaction(requires_new: true) do
        sync = RegulationRndsSync.lock.find_by(regulation_request_id: request.id)
        next sync if sync.nil? && !create

        target = target(request, settings: settings)
        next sync if target == :none
        next nil if sync.nil? && target.status == EXCLUDED

        sync ||= RegulationRndsSync.new(regulation_request: request, initial_load: initial_load, enqueued_at: now)
        apply!(sync, request, target, settings, now)
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

    # Há remessa que saiu depois do último aceite (ou desde sempre, sem aceite)
    # e não teve resposta (timeout; Review Focus 1, fix I2): não se sabe se a
    # RNDS a gravou. O sinal da reconciliação é este, não o `attempts`.
    def unanswered_delivery?(sync)
      return false if sync.new_record?

      scope = RegulationRndsDelivery.where(regulation_rnds_sync_id: sync.id, accepted_at: nil, http_status: nil)
      since = accepted_since(sync)
      scope = scope.where("sent_at > ?", since) if since
      scope.exists?
    end

    # -> [id do pedido] | :all
    def affected_request_ids(event_name, payload)
      payload = payload.to_h.symbolize_keys
      case event_name
      when /\Aregulation_request\./ then [ payload[:regulation_request_id] ].compact
      when "care_offer.changed" then by_offers(payload[:care_offer_id])
      when "care_provider.changed" then by_providers(payload[:care_provider_id])
      when "health_unit.changed" then by_unit(payload[:health_unit_id])
      when "care_regulation.settings_changed", "regulation_rnds.settings_changed" then :all
      else
        resolver = CareRegulation::AppointmentSyncJob::RESOLVERS.fetch(event_name) { raise ArgumentError, "evento não consumido: #{event_name}" }
        id = resolver.call(payload)
        return [] if id.blank?

        AppointmentRequest.where(id: id).where.not(origin_regulation_request_id: nil).pluck(:origin_regulation_request_id)
      end
    end

    # As linhas existentes; com o interruptor (`create`) e `send_external`
    # ligados, também os regulados pelo estado não terminais sem linha
    # (`initial_load`).
    def recompute_all!(now:, create: RndsGate.enabled?(Current.city))
      settings = RegulationRndsSetting.current
      RegulationRequest.where(id: RegulationRndsSync.select(:regulation_request_id)).find_each do |request|
        recompute!(request, create: false, now: now, settings: settings)
      end
      return unless create && settings.send_external

      RegulationRequest.where(state_regulated: true).where.not(status: [ "draft", *CareRegulation::Catalog::TERMINAL_STATUSES ])
                       .where.not(id: RegulationRndsSync.select(:regulation_request_id)).find_each do |request|
        recompute!(request, create: true, initial_load: true, now: now, settings: settings)
      end
    end

    def apply!(sync, request, target, settings, now)
      facts = RiraFacts.for(request: request, settings: settings, credential: nil)
      excluded = target.status == EXCLUDED
      erased = sync.last_rnds_id.present? && facts.patient_cpf.blank? && facts.patient_cns.blank?
      steps = excluded || erased ? [] : RndsStatus.steps(request, since: accepted_since(sync), settings: settings)
      digest = RiraBundle.digest(RiraBundle.build(facts: facts, sync: sync, status: target, now: now))
      digest_changed = sync.desired_digest != digest
      refused_digest = last_delivery_digest(sync)
      changed = [ sync.desired_status, sync.desired_digest, sync.pending_steps ] != [ target.status, digest, steps ]
      sync.assign_attributes(desired_status: target.status, desired_digest: digest, pending_steps: steps)

      was = sync.status
      queued = false
      unless was == SENDING
        status = next_status(sync, was, excluded: excluded, erased: erased, digest_changed: digest_changed, steps: steps,
                                         refused_digest: refused_digest)
        sync.enqueued_at = now if changed
        queued = status == "queued" && was != "queued"
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

    def next_status(sync, was, excluded:, erased:, digest_changed:, steps:, refused_digest:)
      return "erased" if erased

      pending = unanswered_delivery?(sync)
      return EXCLUDED if excluded && !pending && (sync.last_rnds_id.nil? || sync.sent_status == EXCLUDED)
      return was if was == "blocked" && !digest_changed
      # rejected/failed: só com outro conteúdo do que foi recusado (sem
      # remessa, o desejado anterior).
      return was if REFUSED.include?(was) && sync.desired_digest == (refused_digest || sync.desired_digest_was)

      differs = pending || steps.any? || [ sync.desired_status, sync.desired_digest ] != [ sync.sent_status, sync.sent_digest ]
      differs ? "queued" : "idle"
    end

    # O digest da última remessa de documento (a recusada ou falha).
    def last_delivery_digest(sync)
      return nil if sync.new_record?

      RegulationRndsDelivery.where(regulation_rnds_sync_id: sync.id, kind: %w[create replace]).order(:sent_at, :id).last&.digest
    end

    # O `sent_at` da última remessa aceita (nil = nenhuma: todos os passos).
    def accepted_since(sync)
      return nil if sync.new_record?

      RegulationRndsDelivery.where(regulation_rnds_sync_id: sync.id).where.not(accepted_at: nil).maximum(:sent_at)
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

    private_class_method :apply!, :next_status, :last_delivery_digest, :accepted_since, :by_offers, :by_providers, :by_unit
  end
end
