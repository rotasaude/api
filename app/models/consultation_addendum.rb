# Adendo de consulta finalizada (ADR 0031; spec §4): só acréscimo, com motivo
# (10–500) e texto cifrado; pode mudar problemas, condutas e exames
# (item_changes — `changes` colide com ActiveModel::Dirty; na API a chave é `changes`).
# De outro autor, só com abertura justificada válida (opening).
class ConsultationAddendum < ApplicationRecord
  self.table_name = "consultation_addenda"

  MIN_REASON = 10
  MAX_REASON = 500

  encrypts :text

  belongs_to :consultation
  belongs_to :author_user, class_name: "User"
  belongs_to :opening, class_name: "ClinicalRecordOpening", optional: true
end
