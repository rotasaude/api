# Boletim do agente de combate às endemias na visita do 24b (módulo 35a, ADR
# 0054; contrato §1 e §3): um por visita, sempre com domicílio (A-10), com o
# quarteirão congelado na hora. Só acréscimo, como os depósitos e as medidas
# (trigger): a retirada da visita não o muda, só o tira das leituras
# (`valid_inspections`).
class VectorInspection < ApplicationRecord
  belongs_to :home_visit
  belongs_to :household
  belongs_to :city_block, optional: true
  has_many :deposits, class_name: "VectorInspectionDeposit", inverse_of: :vector_inspection
  has_many :measures, class_name: "VectorInspectionMeasure", inverse_of: :vector_inspection
  has_many :samples, class_name: "VectorSample", inverse_of: :vector_inspection

  # Inspeção de visita não retirada.
  scope :valid_inspections, -> { joins(:home_visit).merge(HomeVisit.valid) }

  def inspect = "#<VectorInspection id=#{id} home_visit_id=#{home_visit_id}>"
end
