# app/models/sncr_number_batch.rb
# Lote de números do SNCR de um prescritor (ADR 0034; spec §4): o que o SNCR
# respondeu (início, fim, quantidade), o mês e o número do pedido no mês, e se
# veio do SNCR simulado. Só acréscimo.
class SncrNumberBatch < ApplicationRecord
  KINDS = %w[rce ret].freeze

  belongs_to :user
  has_many :numbers, class_name: "SncrNumber", foreign_key: :batch_id, inverse_of: :batch, dependent: :restrict_with_exception

  def inspect = "#<SncrNumberBatch id=#{id} kind=#{kind} quantity=#{quantity} simulated=#{simulated}>"
end
