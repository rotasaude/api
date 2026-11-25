# Rastro de cada saída enviada à BNAFAR (módulo 27b; contrato §3; Q14): um por
# movimento (`exit`: o registro da saída; `deletion` e `late_reversal`: o
# estorno, apontando o registro original). Só acréscimo (trigger).
class BnafarMovementLink < ApplicationRecord
  belongs_to :stock_movement
  belongs_to :bnafar_record, inverse_of: :movement_links
end
