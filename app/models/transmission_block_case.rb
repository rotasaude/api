# Caso de arbovirose do bloqueio (módulo 35a; contrato §1 e §8): um bloqueio
# por notificação; o número ("caso n", Q8) é único e fixo. Só muda de bloqueio
# (trigger). Nunca sai com dado da pessoa: só id, bloqueio e número.
class TransmissionBlockCase < ApplicationRecord
  ADDED_BY = %w[job user].freeze

  belongs_to :transmission_block, inverse_of: :cases
  belongs_to :disease_notification

  validates :added_by, inclusion: { in: ADDED_BY }

  def inspect = "#<TransmissionBlockCase id=#{id} transmission_block_id=#{transmission_block_id} number=#{number}>"
end
