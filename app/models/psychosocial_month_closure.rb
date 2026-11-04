# Fechamento do mês de um CAPS (ADR 0049): um ativo por CAPS e mês (índice
# parcial); reabrir grava quando, quem e o motivo (cifrado com a chave da
# cidade), uma vez, e nunca apaga (trigger). Com fechamento ativo, nenhuma
# ação nasce naquele mês.
class PsychosocialMonthClosure < ApplicationRecord
  encrypts :reopen_reason

  belongs_to :health_unit
  belongs_to :closed_by_user, class_name: "User"
  belongs_to :reopened_by_user, class_name: "User", optional: true

  scope :active, -> { where(reopened_at: nil) }
end
