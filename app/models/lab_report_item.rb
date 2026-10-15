# Item do laudo (ADR 0037): quais itens da requisição o laudo cobre; só acréscimo.
class LabReportItem < ApplicationRecord
  belongs_to :lab_report
  belongs_to :lab_requisition_item
end
