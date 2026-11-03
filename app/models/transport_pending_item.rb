# Pendência da série (ADR 0048, §14 T20): o dia em que o job não coube o
# paciente (sem lugar ou sem vaga de cadeirante), uma por série e data.
class TransportPendingItem < ApplicationRecord
  belongs_to :transport_series, inverse_of: :transport_pending_items
end
