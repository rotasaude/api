# Exceção do RT ou substituto para liberar um item bloqueado (ADR 0038): só acréscimo; justificativa cifrada.
class LabQcException < ApplicationRecord
  encrypts :justification

  belongs_to :lab_qc_block
  belongs_to :lab_requisition_item
  belongs_to :granted_by_user, class_name: "User"

  def inspect = "#<LabQcException id=#{id} lab_qc_block_id=#{lab_qc_block_id} lab_requisition_item_id=#{lab_requisition_item_id}>"
end
