# app/commands/signatures/to_paper.rb
# Volta ao papel (ADR 0032; spec §5): o impresso do 19a volta a ter espaço de
# assinatura à mão. Pelo autor (user_request, com nota) ou pelo sistema
# (feature_disabled). Quem chama já travou o pedido e conferiu que está pending.
module Signatures
  module ToPaper
    module_function

    def call(request, reason_code:, note: nil, now: Time.current)
      request.update!(status: "returned_to_paper", reason_code: reason_code, return_note: note, resolved_at: now)
      # ADR 0033 (spec §4): a volta ao papel passa o documento clínico a paper
      # (o trigger só aceita sem assinatura gravada); o cancelamento tira o
      # pedido da fila sem mudar o modo.
      if request.document_type == "ClinicalDocument" && reason_code != "document_cancelled"
        ClinicalDocument.where(id: request.document_id, issue_mode: "digital").find_each { |document| document.update!(issue_mode: "paper") }
      end
      DomainEvents.publish("signature.returned_to_paper", request_id: request.id, reason_code: reason_code)
      request
    end
  end
end
