module Regulation
  # Envio de um lote já reivindicado (`sending`) de pedidos de regulação à RNDS
  # (módulo 26c; contrato §3, §9; Q10, Q16, Q23; pré-voo B6, I1–I4; molde do
  # Rnds::Delivery). Um documento em voo por pedido: no máximo um POST por
  # linha e por execução. Por linha:
  #
  #   1. `RndsSync.recompute!` (estado desejado fresco; a linha `sending` só
  #      tem o desejado atualizado);
  #   2. remessa sem resposta depois do último aceite (`unanswered_delivery?`,
  #      não o `attempts`) → `RndsReconcile` ANTES de qualquer POST:
  #      `:adopted`/`:deduplicated` → a linha avança como no aceite (sem novo
  #      POST nesta execução); `:none` → o que saiu não chegou e segue;
  #      `:transient` → espera; `:unauthorized` → pausa;
  #   3. nada a enviar → `idle`, `excluded` (o desejado `excluded` nunca aceito
  #      fecha sem POST; o `excluded` já aceito para) ou `erased`;
  #   4. o próximo documento: o primeiro passo de `pending_steps`, senão o
  #      desejado (`RndsSync.target`);
  #   5. `RndsValidation` e `RiraSkeleton` (Q23, `skeleton:<caminho>`) →
  #      `blocked`, revalida em BLOCKED_RECHECK, `regulation_rnds.blocked` na
  #      transição;
  #   6. a remessa (`create` sem `last_rnds_id`, senão `replace`; payload
  #      cifrado; `sent_at`), com a posse reconferida (I2: `sending` +
  #      `claimed_at` = token, FOR UPDATE; senão LostClaim e nada sai), e o
  #      POST fora de transação com o CNS do responsável (`responsible_cns`);
  #   7. a resposta, com a linha travada e o desejado relido (I1):
  #      - 201 → remessa aceita; `last_rnds_id`, `sent_*`, `attempts 0`; o
  #        passo consumido some no recálculo; `queued` se ainda difere, senão
  #        `idle`/`excluded`; `regulation_rnds.accepted` (e `.excluded`). 201
  #        sem Location → tratada como sem resposta (reconcilia na próxima);
  #      - 422 com EDS-MSG009 → `RndsReconcile` (a cabeça da cadeia, Review
  #        Focus 3) e segue `queued`; `:none` → `rejected` (I3);
  #      - outro 4xx → `rejected` com os códigos (só eles; carry 2), salvo o
  #        desejado ter mudado durante o POST (→ `queued`);
  #      - 401/403 → credencial `unauthorized` (só a do `set_at` lido), esta e
  #        as demais voltam a `queued` sem tentativa, `:paused`;
  #      - 5xx/timeout → `attempts + 1`, espera do Rnds::Backoff; `failed`
  #        quando `retry_window_started_at` (o `sent_at` da 1ª remessa sem
  #        aceite depois do último aceite, Q16/Q25; o transitório a abre se
  #        ainda não havia) passou de GIVE_UP_AFTER. O aceite, o "Reenviar"
  #        manual (`reopen_retry_window!`) e toda parada não transitória (a
  #        recusa, a substituição recusada, o bloqueio, a pausa por 401/403 e,
  #        no RndsDeliverJob, o interruptor desligado ou sem credencial) a
  #        zeram: o tempo parado não conta (nota da Q25, Q16).
  #
  # `error_codes` e `last_error_codes` guardam só códigos da RNDS (Q25).
  #
  # O alvo (simulado × real) sai do `Rnds::Mock.on?` (usable?), lido fora da
  # transação da cidade. Erro inesperado numa linha não trava o lote: só a
  # classe vai ao relatório de erro. CPF, CNS, CID e o Bundle nunca saem daqui.
  class RndsDelivery
    PAUSE_MESSAGE = "A RNDS recusou a credencial durante o envio da regulação; o envio está pausado.".freeze
    MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

    def initialize(city, budget: RndsLimits::BUDGET, clock: MONOTONIC)
      @city = city
      @budget = budget.to_f
      @clock = clock
      settings = Rnds::Mock.on?(city) ? Rnds::Config.simulated : Rnds::Config.real(city)
      @client = Rnds::Client.for(city, kind: "rnds_regulation", settings: settings)
      @credential = IntegrationCredential.find_by!(kind: "rnds_regulation")
      @settings = RegulationRndsSetting.current
    end

    # -> :done | :paused
    def run(syncs)
      token = syncs.first&.claimed_at # o token do claim, o mesmo em todo o lote
      started = @clock.call
      syncs.each_with_index do |sync, index|
        if @clock.call - started > @budget
          RegulationRndsSync.release!(syncs[index..].map(&:id), token: token)
          return :done
        end
        next unless deliver(sync, token) == :paused

        # A pausa por 401/403 é parada (nota da Q25): a janela recomeça no próximo envio.
        RegulationRndsSync.release!(syncs[index..].map(&:id), token: token, reset_window: true)
        return :paused
      end
      :done
    end

    def inspect = "#<Regulation::RndsDelivery>"
    def to_s = inspect
    def pretty_print(pp) = pp.text(inspect)

    private

    def deliver(sync, token)
      now = Time.current
      request = RegulationRequest.find(sync.regulation_request_id)
      RndsSync.recompute!(request, create: false, now: now, settings: @settings)
      sync = RegulationRndsSync.find(sync.id)
      facts = RiraFacts.for(request: request, settings: @settings, credential: @credential)

      if RndsSync.unanswered_delivery?(sync)
        case RndsReconcile.call(sync: sync, client: @client, now: now, token: token, requester_id: @credential.requester_id)
        when :transient then return transient!(sync, token, now)
        when :unauthorized then return pause!(now)
        when :adopted, :deduplicated then return adopted!(sync, token, facts, now)
        end
        sync.reload # :none: o que saiu não chegou à RNDS (remessa fechada, Q25)
      end

      return finish!(sync, token, facts, now) if resting(sync, facts)

      target = sync.pending_steps.first || RndsSync.target(request, settings: @settings)
      verdict = RndsValidation.call(facts: facts, status: target)
      return block!(sync, token, verdict.last, now) if verdict.is_a?(Array)

      bundle = RiraBundle.build(facts: facts, sync: sync, status: target, now: now)
      problems = RiraSkeleton.problems(bundle)
      return block!(sync, token, problems.map { |path| "skeleton:#{path}" }, now) if problems.any?

      snapshot = desired_of(sync)
      delivery = sending!(sync, token, bundle, RiraBundle.situation(target, facts).first, now)
      response = @client.post_bundle(bundle, practitioner_cns: @client.responsible_cns)
      respond(sync, token, facts, delivery, response, snapshot)
    rescue RegulationRndsSync::LostClaim
      :lost # outra execução é dona da linha: não envia, não mexe
    rescue *Maintenance::CityConnectionErrors::CLASSES
      retry_later(sync, token)
    rescue StandardError => e
      Rails.error.report(RuntimeError.new("regulation rnds delivery: #{e.class.name}"), handled: true, severity: :error)
      retry_later(sync, token)
    end

    def respond(sync, token, facts, delivery, response, snapshot)
      now = Time.current
      case response.status
      when :accepted
        # 201 sem Location: não há id para a cadeia. Fica sem resposta e a
        # próxima rodada reconcilia (nunca um segundo `create`).
        return transient!(sync, token, now) if response.rnds_id.blank?

        accept!(sync, token, facts, delivery, response, now)
      when :rejected
        codes = RndsReconcile.rnds_codes(response)
        delivery.update!(http_status: response.http_status || 422, error_codes: codes)
        return replaced!(sync, token, facts, codes, now) if codes.include?(RndsLimits::REPLACED_CODE)

        reject!(sync, token, codes, snapshot, now)
      when :unauthorized
        delivery.update!(http_status: response.http_status || 401)
        pause!(now)
      else
        delivery.update!(http_status: response.http_status) if response.http_status
        transient!(sync, token, now)
      end
    end

    def accept!(sync, token, facts, delivery, response, now)
      own!(sync, token) do |locked|
        delivery.update!(accepted_at: now, rnds_id: response.rnds_id, http_status: response.http_status || 201)
        locked.update!(last_rnds_id: response.rnds_id, last_accepted_at: now, sent_status: delivery.mira_status,
                       sent_digest: delivery.digest, attempts: 0, last_error_codes: [], blocked_reasons: [], retry_window_started_at: nil)
        conclude!(locked, facts, now)
        published!(locked, delivery.mira_status)
      end
      :accepted
    end

    # A reconciliação adotou a remessa sem resposta: a linha avança como no aceite.
    def adopted!(sync, token, facts, now)
      own!(sync, token) do |locked|
        conclude!(locked, facts, now)
        published!(locked, locked.sent_status)
      end
      :adopted
    end

    # EDS-MSG009: o `last_rnds_id` já foi substituído. A cadeia diz quem é a
    # cabeça (Review Focus 3); sem cabeça, `rejected` (I3, sem laço).
    def replaced!(sync, token, facts, codes, now)
      case RndsReconcile.call(sync: RegulationRndsSync.find(sync.id), client: @client, now: now, token: token,
                              requester_id: @credential.requester_id)
      when :adopted, :deduplicated then finish!(sync, token, facts, now)
      when :transient then transient!(sync, token, now)
      when :unauthorized then pause!(now)
      else
        own!(sync, token) do |locked|
          locked.update!(status: "rejected", last_error_codes: codes, retry_window_started_at: nil)
          event!("regulation_rnds.rejected", locked)
        end
        :rejected
      end
    end

    # Recusa: `rejected`, salvo o desejado ter mudado durante o POST (I1).
    def reject!(sync, token, codes, snapshot, now)
      own!(sync, token) do |locked|
        refresh!(locked, now)
        if desired_of(locked) == snapshot
          locked.update!(status: "rejected", last_error_codes: codes, retry_window_started_at: nil)
          event!("regulation_rnds.rejected", locked)
        else
          locked.update!(status: "queued", next_attempt_at: now)
        end
      end
      :rejected
    end

    def block!(sync, token, reasons, now)
      own!(sync, token) do |locked|
        was_blocked = locked.blocked_reasons.any?
        locked.update!(status: "blocked", blocked_reasons: reasons, next_attempt_at: now + RndsLimits::BLOCKED_RECHECK,
                       retry_window_started_at: nil)
        event!("regulation_rnds.blocked", locked) unless was_blocked
      end
      :blocked
    end

    # Falha transitória (5xx, timeout, rede, erro nosso): nova tentativa com
    # espera; `failed` quando a janela (Q16/Q25) passou de GIVE_UP_AFTER. Sem
    # janela aberta (a reconciliação que falha depois do "Reenviar", antes de
    # qualquer POST), ela abre aqui. Só a linha muda: a remessa já respondida
    # nunca é tocada de novo (trigger).
    def transient!(sync, token, now)
      own!(sync, token) do |locked|
        attempts = locked.attempts + 1
        start = locked.retry_window_started_at || now
        gave_up = start <= now - RndsLimits::GIVE_UP_AFTER
        locked.update!(status: gave_up ? "failed" : "queued", attempts: attempts, next_attempt_at: now + Rnds::Backoff.wait(attempts),
                       retry_window_started_at: start)
      end
      :transient
    end

    def retry_later(sync, token)
      transient!(sync, token, Time.current)
    rescue RegulationRndsSync::LostClaim
      :lost
    end

    # Só marca a credencial usada no lote: trocada no meio (set_at novo), a
    # nova não herda a recusa da antiga. A linha volta pelo release! do run.
    def pause!(now)
      IntegrationCredential.where(id: @credential.id, set_at: @credential.set_at)
                           .update_all(last_check_status: "unauthorized", last_check_at: now, last_check_message: PAUSE_MESSAGE,
                                       updated_at: now)
      :paused
    end

    # Fecha a linha sem POST (nada a enviar) ou depois de uma adoção.
    def finish!(sync, token, facts, now)
      own!(sync, token) { |locked| conclude!(locked, facts, now) }
      :finished
    end

    # Com a linha travada: o desejado relido (o passo consumido some) e a
    # situação de repouso, ou `queued` (agora) se ainda há o que enviar.
    def conclude!(locked, facts, now)
      refresh!(locked, now)
      status = resting(locked, facts) || "queued"
      if status == "queued"
        locked.update!(status: status, next_attempt_at: now, blocked_reasons: [])
      else
        locked.update!(status: status, next_attempt_at: nil, attempts: 0, blocked_reasons: [])
      end
    end

    # O recálculo do RndsSync (a linha `sending` só tem o desejado mexido).
    def refresh!(locked, now)
      RndsSync.recompute!(RegulationRequest.find(locked.regulation_request_id), create: false, now: now, settings: @settings)
      locked.reload
    end

    # idle | excluded | erased | nil (há o que enviar): a regra única do
    # RndsSync.resting_status, para uma linha que não espera resposta.
    def resting(sync, facts)
      return nil if RndsSync.unanswered_delivery?(sync)

      RndsSync.resting_status(sync, erased: RndsSync.erased?(sync, facts))
    end

    # A janela de desistência começa na 1ª remessa sem aceite depois do
    # último aceite (Q16/Q25): a que sai agora, se ainda não havia.
    def sending!(sync, token, bundle, code, now)
      own!(sync, token) do |locked|
        locked.update!(retry_window_started_at: now) if locked.retry_window_started_at.nil?
        RegulationRndsDelivery.create!(regulation_rnds_sync_id: locked.id, kind: locked.last_rnds_id ? "replace" : "create",
                                       mira_status: code, digest: RiraBundle.digest(bundle), payload: JSON.generate(bundle), sent_at: now)
      end
    end

    def own!(sync, token)
      RegulationRndsSync.transaction(requires_new: true) do
        locked = RegulationRndsSync.where(id: sync.id, status: RndsSync::SENDING, claimed_at: token).lock("FOR UPDATE").first
        raise RegulationRndsSync::LostClaim unless locked

        yield locked
      end
    end

    def desired_of(sync) = [ sync.desired_status, sync.desired_digest, sync.pending_steps ]

    def published!(sync, sent_status)
      event!("regulation_rnds.accepted", sync)
      event!("regulation_rnds.excluded", sync) if sent_status == RndsSync::EXCLUDED
    end

    def event!(name, sync)
      DomainEvents.publish(
        name,
        regulation_rnds_sync_id: sync.id, regulation_request_id: sync.regulation_request_id
      )
    end
  end
end
