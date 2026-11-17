# Cadência de visita (módulo 35a; contrato §1; W-10): dias entre visitas por
# (bairro, risco, ponto estratégico); bairro nulo = cidade, risco nulo =
# qualquer. Única pela tripla, com nulo como valor (NULLS NOT DISTINCT). O
# ponto estratégico não tem risco (CHECK). Apagável (o PUT /cadences troca a
# lista inteira); o TRUNCATE é recusado (trigger).
class VectorCadence < ApplicationRecord
  belongs_to :neighborhood, optional: true

  validates :risk_class, inclusion: { in: VectorControl::Catalog::RISK_CLASSES }, allow_nil: true
  validates :days, inclusion: { in: VectorControl::Catalog::CADENCE_DAYS }

  def inspect = "#<VectorCadence id=#{id} version=#{version}>"
end
