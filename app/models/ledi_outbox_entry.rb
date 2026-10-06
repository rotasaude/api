# Uma ficha na fila de saída LEDI da cidade (ADR 0028; spec §6.3). O payload é o
# DadoTransporteThrift serializado, em Base64, cifrado com a chave da cidade;
# vai a nulo no aceite (CHECK + trigger). Transições de envio: Ledi::Delivery.
class LediOutboxEntry < ApplicationRecord
  self.table_name = "ledi_outbox"

  STATUSES = %w[pending sending accepted rejected failed].freeze

  encrypts :payload

  scope :for_competence, ->(competence) { where(competence: competence) }

  def bytes = payload && Base64.strict_decode64(payload)

  def bytes=(raw)
    self.payload = raw && Base64.strict_encode64(raw)
  end

  # Reivindica um lote vencido: transação curta, SKIP LOCKED (duas execuções
  # nunca pegam a mesma linha), e a linha sai como `sending` — o HTTP acontece
  # FORA desta transação.
  def self.claim!(limit:)
    ids = transaction do
      picked = where(status: "pending").where(next_attempt_at: ..Time.current)
               .order(:next_attempt_at, :id).limit(limit).lock("FOR UPDATE SKIP LOCKED").pluck(:id)
      mark_sending(picked)
      picked
    end
    where(id: ids).order(:next_attempt_at, :id).to_a
  end

  def self.mark_sending(ids)
    return if ids.empty?

    where(id: ids).update_all([ "status = 'sending', updated_at = :now, first_attempt_at = COALESCE(first_attempt_at, :now)",
                                { now: Time.current } ])
  end

  def self.release!(ids)
    where(id: ids, status: "sending").update_all(status: "pending", updated_at: Time.current)
  end

  def self.release_stale!(before:)
    where(status: "sending").where(updated_at: ...before).update_all(status: "pending", updated_at: Time.current)
  end

  def accept!
    transaction do
      update!(status: "accepted", accepted_at: Time.current, payload: nil, last_error: nil, attempts: attempts + 1)
      DomainEvents.publish("ledi.ficha_accepted", outbox_id: id, ficha_type: ficha_type, competence: competence)
    end
  end

  def reject!(message)
    transaction do
      update!(status: "rejected", last_error: Ledi::ErrorText.sanitize(message), attempts: attempts + 1)
      DomainEvents.publish("ledi.ficha_rejected", outbox_id: id, ficha_type: ficha_type, competence: competence)
    end
  end

  # Falha transitória: nova tentativa depois de `wait`, ou failed quando a
  # primeira tentativa já passou de `give_up_after`.
  def retry_later!(error:, wait:, give_up_after:, now: Time.current)
    started = first_attempt_at || now
    status = started <= now - give_up_after ? "failed" : "pending"
    update!(status: status, attempts: attempts + 1, last_error: Ledi::ErrorText.sanitize(error),
            next_attempt_at: now + wait)
  end
end
