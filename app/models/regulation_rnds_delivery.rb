# Remessa do envio da regulação à RNDS (módulo 26c; Q16, Q17): cada chamada
# (create, replace, delete) de um pedido. O payload é cifrado com a chave da
# cidade (CityEncryption), é NULL no `delete` e vira NULL depois de
# PAYLOAD_DAYS, aceita ou não (Q17); a resposta (`accepted_at`, `rnds_id`,
# `http_status`, `error_codes`, só os códigos da RNDS, Q25) grava-se uma vez,
# só enquanto não houve resposta HTTP; `unanswered_closed_at` (Q25) marca a
# remessa sem resposta que a reconciliação viu não ter chegado; o resto nunca
# muda; nunca é apagada (trigger). O payload não sai em inspect, to_s,
# pretty_print nem as_json.
class RegulationRndsDelivery < ApplicationRecord
  DOCUMENT_KINDS = %w[create replace].freeze

  encrypts :payload

  belongs_to :regulation_rnds_sync, inverse_of: :deliveries

  # Remessas de documento (create/replace) sem resposta (sem `http_status` nem
  # aceite), não fechadas pela reconciliação, enviadas depois do último aceite
  # da linha (sem aceite, todas): não se sabe se a RNDS as gravou. O predicado
  # único do RndsSync.unanswered_delivery? e da RndsReconcile.
  def self.unanswered_for(sync)
    scope = where(regulation_rnds_sync_id: sync.id, kind: DOCUMENT_KINDS, accepted_at: nil, http_status: nil, unanswered_closed_at: nil)
    since = accepted_since(sync)
    since ? scope.where("sent_at > ?", since) : scope
  end

  # O `sent_at` da última remessa aceita da linha (nil = nenhuma).
  def self.accepted_since(sync) = where(regulation_rnds_sync_id: sync.id).where.not(accepted_at: nil).maximum(:sent_at)

  def inspect = "#<RegulationRndsDelivery id=#{id} kind=#{kind} http_status=#{http_status.inspect}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
