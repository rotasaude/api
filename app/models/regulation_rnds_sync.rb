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

  def inspect = "#<RegulationRndsSync id=#{id} status=#{status}>"
end
