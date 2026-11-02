# Excursão de temperatura aberta por uma leitura fora da faixa (ADR 0047):
# bloqueia os lotes do local (stock_lot_blocks) até a conduta. Só a decisão
# muda, uma vez (trigger).
class ColdChainExcursion < ApplicationRecord
  belongs_to :cold_chain_reading, inverse_of: :excursion
  belongs_to :stock_location
  belongs_to :decided_by_user, class_name: "User", optional: true
  has_many :stock_lot_blocks, inverse_of: :cold_chain_excursion

  scope :open_excursions, -> { where(decided_at: nil) }
end
