# Par (bairro, unidade) da cobertura (ADR 0023): ligar cria a linha, desligar
# apaga. A trilha é o evento neighborhood.coverage_changed.
class NeighborhoodCoverage < ApplicationRecord
  belongs_to :neighborhood
  belongs_to :health_unit
end
