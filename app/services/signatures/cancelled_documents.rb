# Desvio 6 (ADR 0033): pedido pendente de documento clínico cancelado volta ao
# papel com document_cancelled (o modo do documento não muda) e sai da lista.
# Quem chama já travou os pedidos (job, lote, varredura, cancelamento).
module Signatures
  module CancelledDocuments
    module_function

    def retire!(requests, now: Time.current)
      ids = requests.select { |request| request.document_type == "ClinicalDocument" }.map(&:document_id)
      return requests if ids.empty?

      cancelled = ClinicalDocument.where(id: ids, status: "cancelled").pluck(:id).to_set
      requests.reject do |request|
        next false unless request.document_type == "ClinicalDocument" && cancelled.include?(request.document_id)

        ToPaper.call(request, reason_code: "document_cancelled", now: now)
        true
      end
    end
  end
end
