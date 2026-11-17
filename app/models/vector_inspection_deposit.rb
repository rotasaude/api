# Depósitos de um grupo na inspeção (módulo 35a; contrato §1 e §3.5): um por
# grupo, contagens 0–999 e as desigualdades do §3.5 também no banco. Só
# acréscimo (trigger).
class VectorInspectionDeposit < ApplicationRecord
  belongs_to :vector_inspection, inverse_of: :deposits

  def inspect = "#<VectorInspectionDeposit id=#{id} group=#{group}>"
end
