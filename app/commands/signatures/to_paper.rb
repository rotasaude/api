# app/commands/signatures/to_paper.rb
# Volta ao papel (ADR 0032; spec §5): o impresso do 19a volta a ter espaço de
# assinatura à mão. Pelo autor (user_request, com nota) ou pelo sistema
# (feature_disabled). Quem chama já travou o pedido e conferiu que está pending.
module Signatures
  module ToPaper
    LAB_REPORT_REASONS = %w[feature_disabled document_cancelled].freeze

    module_function

    def call(request, reason_code:, note: nil, now: Time.current)
      # ADR 0037 (B13, B56): laudo não vai ao papel. Só o sistema devolve o
      # pedido — interruptor desligado (feature_disabled) ou laudo que não pode
      # mais valer (document_cancelled): o laudo sai (Lab::WithdrawReport).
      if request.document_type == "LabReport"
        raise ArgumentError, "laudo só sai do pedido pelo sistema" unless LAB_REPORT_REASONS.include?(reason_code)

        Lab::WithdrawReport.call(request.document_id)
      end
      request.update!(status: "returned_to_paper", reason_code: reason_code, return_note: note, resolved_at: now)
      # ADR 0033 (spec §4): a volta ao papel passa o documento clínico a paper
      # (o trigger só aceita sem assinatura gravada); o cancelamento tira o
      # pedido da fila sem mudar o modo.
      if request.document_type == "ClinicalDocument" && reason_code != "document_cancelled"
        ClinicalDocument.where(id: request.document_id, issue_mode: "digital").find_each do |document|
          document.update!(issue_mode: "paper")
          Sncr::Stock.void!(document: document, now: now) # ADR 0034, Desvio 11
        end
      end
      DomainEvents.publish("signature.returned_to_paper", request_id: request.id, reason_code: reason_code)
      request
    end
  end
end
