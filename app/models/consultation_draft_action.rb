# Trilha do rascunho de consulta órfão (card rotasaude/api#51; módulo 19a, ADR
# 0031): cada descarte ou designação feito pelo admin municipal, com a autora
# anterior, a nova (só na designação) e o motivo (cifrado; nunca vai a evento
# nem log). Só acréscimo (trigger); a re-cifra regrava só o motivo.
class ConsultationDraftAction < ApplicationRecord
  ACTIONS = %w[discarded reassigned].freeze

  encrypts :reason

  belongs_to :consultation
  belongs_to :attendance
  belongs_to :by_user, class_name: "User"
  belongs_to :previous_author_user, class_name: "User"
  belongs_to :new_author_user, class_name: "User", optional: true

  def inspect = "#<ConsultationDraftAction id=#{id} action=#{action} consultation_id=#{consultation_id}>"
end
