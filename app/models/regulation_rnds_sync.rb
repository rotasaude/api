# Estado do envio de um pedido de regulação à RNDS (módulo 26c; Q6, Q16): um
# por pedido. O identificador do Bundle (`bundle_identifier`, uuid por padrão;
# texto, para caber o marcador do simulado), o último documento aceito, as
# situações MIRA enviada e desejada com as impressões digitais, os passos
# pendentes, a situação da linha (`Regulation::RndsCatalog::SYNC_STATUSES`),
# os motivos de bloqueio, os códigos de erro (só o código), o cursor
# (`enqueued_at`) e o token do claim (`claimed_at`). Nunca é apagado
# (trigger). O inspect mostra só o id e a situação.
class RegulationRndsSync < ApplicationRecord
  attribute :bundle_identifier, :string, default: -> { SecureRandom.uuid }

  belongs_to :regulation_request
  has_many :deliveries, -> { order(:sent_at, :id) }, class_name: "RegulationRndsDelivery", inverse_of: :regulation_rnds_sync

  CLAIMABLE = %w[queued blocked].freeze

  # A execução que reivindicou perdeu a linha (`release_stale!` + claim de
  # outra execução): ela não envia, não grava e não devolve a linha (I2).
  class LostClaim < StandardError; end

  # Reivindica as linhas vencidas (`queued`/`blocked` com `next_attempt_at <=
  # now`) numa transação curta com SKIP LOCKED: duas execuções nunca pegam a
  # mesma linha, e a linha que o RndsSyncJob está recalculando (travada) fica
  # para a rodada seguinte. Primeiro as que não são da carga inicial, até
  # `limit`; depois as da carga, até `initial_limit` (o ritmo da Task 11).
  # Elas saem `sending` com `claimed_at = now`: o TOKEN do lote, o mesmo em
  # todas, relido do banco (a precisão da coluna). O HTTP acontece fora daqui.
  def self.claim!(limit:, initial_limit:, now: Time.current)
    ids = transaction do
      due = where(status: CLAIMABLE).where(next_attempt_at: ..now).order(:next_attempt_at, :enqueued_at, :id).lock("FOR UPDATE SKIP LOCKED")
      picked = due.where(initial_load: false).limit(limit).pluck(:id)
      picked += due.where(initial_load: true).limit(initial_limit).pluck(:id)
      where(id: picked).update_all(status: "sending", claimed_at: now, updated_at: now) if picked.any?
      picked
    end
    where(id: ids).order(:initial_load, :next_attempt_at, :enqueued_at, :id).to_a
  end

  # Devolve a `queued` sem contar tentativa (pausa, orçamento esgotado,
  # ensure): só as linhas ainda deste lote (`token`).
  def self.release!(ids, token:, now: Time.current)
    where(id: ids, status: "sending", claimed_at: token).update_all(status: "queued", updated_at: now)
  end

  # `sending` esquecido (processo morto no meio do lote) volta à fila. Pela
  # posse (`claimed_at`), não pelo `updated_at`, que o consumidor mexe (I2).
  def self.release_stale!(before:, now: Time.current)
    where(status: "sending").where("claimed_at IS NULL OR claimed_at < ?", before).update_all(status: "queued", updated_at: now)
  end

  def inspect = "#<RegulationRndsSync id=#{id} status=#{status}>"
end
