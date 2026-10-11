# Motivo do descarte e da designação do rascunho órfão (card rotasaude/api#51):
# a mesma regra do cancelamento de documento (ClinicalDocument::CANCEL_REASON,
# 10 a 500 depois do squish). Cifrado na trilha; nunca vai a evento nem log.
module ConsultationDrafts
  module Reason
    module_function

    # O motivo normalizado, ou nil quando não vale.
    def normalize(reason)
      note = reason.is_a?(String) ? reason.squish : ""
      ClinicalDocument::CANCEL_REASON.cover?(note.size) ? note : nil
    end
  end
end
