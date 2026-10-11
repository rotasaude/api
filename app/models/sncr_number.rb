# app/models/sncr_number.rb
# Número SNCR do estoque de um prescritor (ADR 0034; spec §4). free → used
# (na transação da emissão, com o documento) → voided (cancelamento ou volta
# ao papel). O número nunca vai a log, evento ou inspect.
class SncrNumber < ApplicationRecord
  KINDS = %w[rce ret].freeze
  STATUSES = %w[free used voided].freeze
  FORMAT = /\A\d{4}\.\d-\d{2}\.\d{7}\z/

  belongs_to :batch, class_name: "SncrNumberBatch", inverse_of: :numbers
  belongs_to :user

  scope :available, -> { where(status: "free") }

  def inspect = "#<SncrNumber id=#{id} kind=#{kind} status=#{status} simulated=#{simulated}>"
  alias_method :to_s, :inspect
end
