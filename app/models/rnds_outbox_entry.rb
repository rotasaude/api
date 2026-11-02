# Uma entrada na fila de envio à RNDS (ADR 0047, Desvio 12): uma por dose
# (application) e por cancelamento (cancellation), índice único. O payload é o
# Bundle RIA-R cifrado com a chave da cidade e vai a nulo no aceite (CHECK).
# Nunca é apagada (trigger). Nada do paciente em inspect, to_s, pretty_print
# nem as_json — só o id.
class RndsOutboxEntry < ApplicationRecord
  self.table_name = "rnds_outbox"

  encrypts :payload

  belongs_to :immunization, inverse_of: :rnds_outbox_entries

  # Situações em que a entrada já foi (ou pode ter sido) enviada à RNDS.
  # `pending` com `first_attempt_at` também conta: um timeout deixa o
  # resultado desconhecido. `blocked` nunca saiu (a validação NT 115 vem antes
  # do envio).
  ATTEMPTED_STATUSES = %w[sending accepted rejected failed].freeze

  # `application` de dose CANCELADA que nunca foi tentada (`pending` sem
  # tentativa ou `blocked`): não vai à RNDS e não nasce `cancellation` para ela
  # (ruling do Fix round 1 da Task 9). Fica como está — a fila não se apaga e
  # não há status novo — e o claim da Task 13 a exclui com `not_withdrawn`.
  scope :withdrawn, lambda {
    joins(:immunization).where(kind: "application").where.not(immunizations: { cancelled_at: nil })
                        .where("rnds_outbox.status = 'blocked' OR (rnds_outbox.status = 'pending' AND rnds_outbox.first_attempt_at IS NULL)")
  }
  scope :not_withdrawn, -> { where.not(id: withdrawn.select(:id)) }

  # O que o job pode reivindicar (Task 13): `pending`/`blocked` vencidas, nunca
  # a `application` retirada (V23) e, para a `cancellation`, só com a
  # `application` da mesma dose `accepted` (o cancelamento espera o aceite do
  # original). A `cancellation` cujo original virou `rejected`/`failed` (estava
  # em voo quando a dose foi cancelada) fica `pending` para sempre FORA daqui e
  # fora das pendências (Vaccination::Pending.effective): é a "cancelação
  # órfã", encerrada sem envio — nada a desfazer na RNDS.
  scope :claimable, lambda { |now = Time.current|
    not_withdrawn.where(status: %w[pending blocked]).where(next_attempt_at: ..now).where(<<~SQL.squish)
      rnds_outbox.kind = 'application' OR EXISTS (SELECT 1 FROM rnds_outbox original
        WHERE original.immunization_id = rnds_outbox.immunization_id AND original.kind = 'application' AND original.status = 'accepted')
    SQL
  }

  def attempted? = ATTEMPTED_STATUSES.include?(status) || (status == "pending" && first_attempt_at.present?)

  # A execução que reivindicou perdeu a linha (`release_stale!` + claim de
  # outra execução): ela não envia nem devolve a linha.
  class LostClaim < StandardError; end

  # Reivindica um lote vencido: transação curta, SKIP LOCKED (duas execuções
  # nunca pegam a mesma linha; o cancelamento da dose trava a `application`
  # FOR UPDATE e o claim passa por cima), e a linha sai `sending` — o HTTP
  # acontece FORA desta transação. `first_attempt_at` NÃO é gravado aqui: só
  # quando o Bundle sai (`sending!`), porque validação, bloqueio e credencial
  # recusada não chegam à RNDS (V23: "nunca tentada" = sem first_attempt_at).
  #
  # Posse: o claim grava `last_attempted_at` = o instante do claim, o TOKEN do
  # lote (o mesmo em todas as linhas dele). `sending!` e `release!` só agem
  # sobre a linha ainda `sending` com esse token: uma execução lenta cujas
  # linhas foram devolvidas por `release_stale!` e reivindicadas por outra
  # nunca as envia de novo nem as tira da outra.
  def self.claim!(limit:, now: Time.current)
    ids = transaction do
      picked = claimable(now).order(:next_attempt_at, :id).limit(limit).lock("FOR UPDATE SKIP LOCKED").pluck(:id)
      where(id: picked).update_all(status: "sending", block_reason: nil, last_attempted_at: now, updated_at: now) if picked.any?
      picked
    end
    where(id: ids).order(:next_attempt_at, :id).to_a
  end

  # Devolve a pending sem contar tentativa (pausa, credencial recusada, ensure,
  # orçamento do lote esgotado) — só as linhas ainda deste lote (`token`).
  def self.release!(ids, token:, now: Time.current)
    where(id: ids, status: "sending", last_attempted_at: token).update_all(status: "pending", updated_at: now)
  end

  # `sending` esquecido (processo morto no meio do lote) volta à fila.
  def self.release_stale!(before:, now: Time.current)
    where(status: "sending").where(updated_at: ...before).update_all(status: "pending", updated_at: now)
  end

  # O Bundle vai sair agora: reafirma a posse (linha travada, ainda `sending`
  # com o token deste lote; senão LostClaim e nada sai), guarda o payload
  # cifrado e marca a tentativa ANTES do HTTP (timeout ou processo morto
  # depois daqui = resultado desconhecido = tentada). Devolve o
  # `first_attempt_at` anterior, para `unsent!` desfazer.
  def sending!(bundle, token:, now: Time.current)
    transaction do
      owned = self.class.where(id: id, status: "sending", last_attempted_at: token).lock("FOR UPDATE").pick(:id)
      raise LostClaim unless owned

      previous = first_attempt_at
      update!(payload: JSON.generate(bundle), first_attempt_at: first_attempt_at || now, sent_at: now)
      previous
    end
  end

  # A RNDS recusou a credencial antes de aceitar o Bundle: não foi tentada.
  def unsent!(previous_first_attempt_at)
    update!(first_attempt_at: previous_first_attempt_at)
  end

  def accept!(rnds_id, now: Time.current)
    transaction do
      update!(status: "accepted", accepted_at: now, rnds_id: rnds_id, payload: nil, error: nil, block_reason: nil,
              attempts: attempts + 1, last_attempted_at: now)
      DomainEvents.publish("rnds.immunization_accepted", outbox_id: id, immunization_id: immunization_id)
    end
  end

  # `error`: o diagnóstico da RNDS já limpo pelo cliente (Rnds::Errors.sanitize).
  def reject!(error, now: Time.current)
    transaction do
      update!(status: "rejected", error: Rnds::Errors.sanitize(error).presence || "rejected", attempts: attempts + 1,
              last_attempted_at: now)
      DomainEvents.publish("rnds.immunization_rejected", outbox_id: id, immunization_id: immunization_id)
    end
  end

  # NT 115 (Rnds::Validation): nunca saiu; sem payload, revalida em 1 h.
  def block!(reason, now: Time.current)
    update!(status: "blocked", block_reason: reason, payload: nil, error: nil, next_attempt_at: now + Rnds::Backoff::BLOCKED_RECHECK)
  end

  # Falha transitória: nova tentativa depois de `wait`; `failed` só quando a
  # PRIMEIRA tentativa de envio já passou de `give_up_after` (V7). Entrada que
  # nunca saiu (CADSUS ou banco fora do ar antes do envio) não desiste.
  def retry_later!(error:, wait:, give_up_after:, now: Time.current)
    gave_up = first_attempt_at.present? && first_attempt_at <= now - give_up_after
    update!(status: gave_up ? "failed" : "pending", attempts: attempts + 1, error: error, last_attempted_at: now,
            next_attempt_at: now + wait)
  end

  # Encerrada sem envio, com o motivo (ex.: cancelamento cujo original foi
  # aceito sem rnds_id — não há como montar o Bundle substituto).
  def fail!(error, now: Time.current)
    update!(status: "failed", error: error, payload: nil, last_attempted_at: now)
  end

  def inspect = "#<RndsOutboxEntry id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
