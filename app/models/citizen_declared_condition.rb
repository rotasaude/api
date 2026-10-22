# app/models/citizen_declared_condition.rb
# Condição de saúde declarada pelo próprio cidadão no wpda (ADR 0040; spec
# §4). Nunca é diagnóstico. Cifrada; retirar grava withdrawn_at; a exclusão
# LGPD apaga (não retém).
class CitizenDeclaredCondition < ApplicationRecord
  encrypts :condition

  belongs_to :citizen

  scope :current, -> { where(withdrawn_at: nil) }

  validates :condition, inclusion: { in: CareLines::Catalog::CONDITIONS }
end
