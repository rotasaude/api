# Uma chamada à BNAFAR de uma remessa (módulo 27b; Q8, Q14): `post` (envio ou
# reenvio), `put` (correção) ou `delete` (estorno), com o protocolo, as
# tentativas e a evidência cURL (só em homologação, trigger; sem token nem
# senha). A evidência e o corpo não saem em inspect, to_s, pretty_print nem
# as_json.
#
# Fila do Bnafar::DeliverJob (Task 11), no molde do RndsOutboxEntry: o claim
# pega, com FOR UPDATE SKIP LOCKED, os lotes vencidos do ambiente em uso —
# `queued` (a enviar; sai `sending`) e `processing` (a consultar; fica
# `processing` com a posse por STALE_SENDING em `next_attempt_at`). O `post`
# só sai com a remessa já montada e em voo (`queued | sending | processing`:
# nem `building`, nem `lost`); `put` e `delete` têm ciclo próprio (R10).
# Posse: `last_attempted_at` = o instante do claim, o mesmo em todo o lote;
# quem perdeu a posse (`release_stale!` + claim de outro) não envia nem devolve.
class BnafarBatch < ApplicationRecord
  belongs_to :bnafar_submission, inverse_of: :batches
  has_many :records, class_name: "BnafarRecord", inverse_of: :bnafar_batch

  INFLIGHT = %w[queued sending processing].freeze

  class LostClaim < StandardError; end

  scope :claimable, lambda { |environment, now = Time.current|
    joins(:bnafar_submission).where(bnafar_submissions: { environment: environment })
                             .where("bnafar_batches.next_attempt_at IS NULL OR bnafar_batches.next_attempt_at <= ?", now)
                             .where(<<~SQL.squish, INFLIGHT)
                               bnafar_batches.status = 'processing' OR (bnafar_batches.status = 'queued'
                                 AND (bnafar_batches.operation <> 'post' OR bnafar_submissions.status IN (?)))
                             SQL
  }

  def self.claim!(limit:, environment:, now: Time.current)
    ids = transaction do
      picked = claimable(environment, now).order(Arel.sql("bnafar_batches.next_attempt_at NULLS FIRST, bnafar_batches.id"))
                                          .limit(limit).lock("FOR UPDATE OF bnafar_batches SKIP LOCKED").pluck(:id)
      if picked.any?
        where(id: picked, status: "queued").update_all(status: "sending", last_attempted_at: now, updated_at: now)
        where(id: picked, status: "processing").update_all(last_attempted_at: now, next_attempt_at: now + Bnafar::Limits::STALE_SENDING,
                                                           updated_at: now)
      end
      picked
    end
    where(id: ids).order(:id).to_a
  end

  # Devolve sem contar tentativa (pausa, ensure, orçamento esgotado): só o que
  # ainda é deste claim (`token`).
  def self.release!(ids, token:, now: Time.current)
    where(id: ids, status: "sending", last_attempted_at: token).update_all(status: "queued", updated_at: now)
    # A consulta que não chegou ao fim ainda tem a posse (o prazo do claim).
    where(id: ids, status: "processing", last_attempted_at: token, next_attempt_at: token + Bnafar::Limits::STALE_SENDING)
      .update_all(next_attempt_at: now, updated_at: now)
  end

  # `sending` esquecido (processo morto no meio do lote) volta à fila.
  def self.release_stale!(before:, now: Time.current)
    where(status: "sending").where(updated_at: ...before).update_all(status: "queued", updated_at: now)
  end

  # Reafirma a posse com a linha travada; senão LostClaim. -> self (recarregado)
  def own!(token, status)
    owned = self.class.where(id: id, status: status, last_attempted_at: token).lock("FOR UPDATE").exists?
    raise LostClaim unless owned

    reload
  end

  def inspect = "#<BnafarBatch id=#{id} operation=#{operation} status=#{status} protocol=#{protocol.inspect}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
