# Imóvel sorteado do LIRAa (módulo 35a; contrato §1 e §7): um por domicílio no
# estrato; pendente, inspecionado ou substituído (o substituto cita o
# original). Só muda o status (pending → inspected | substituted, e de volta a
# pending quando a visita é retirada) e o substituto, e nada com o levantamento
# fechado. Nunca apagado (trigger).
class LiraaDrawItem < ApplicationRecord
  STATUSES = %w[pending inspected substituted].freeze

  belongs_to :liraa_stratum, inverse_of: :draw_items
  belongs_to :city_block
  belongs_to :household
  belongs_to :substitute_of, class_name: "LiraaDrawItem", optional: true

  validates :status, inclusion: { in: STATUSES }

  def inspect = "#<LiraaDrawItem id=#{id} liraa_stratum_id=#{liraa_stratum_id} position=#{position} status=#{status}>"
end
