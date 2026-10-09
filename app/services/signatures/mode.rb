# app/services/signatures/mode.rb
# Modo de cada documento (ADR 0032; contrato §2): manual (sem pedido, ou de
# volta ao papel), pending, digital. Calculado; as tabelas do 19a não mudam.
# Duas consultas (pedidos e assinaturas), sem ler colunas cifradas. No digital,
# `simulated` sai SEMPRE como booleano (R5: marcador legal não depende de
# ausência de chave).
module Signatures
  module Mode
    module_function

    def blocks(documents)
      return {} if documents.empty?

      # Pelo consultation_id (indexado): a consulta e os adendos dela.
      consultation_ids = documents.map { |document| DocumentTypes.consultation_id(document) }.uniq
      requests = SignatureRequest.where(consultation_id: consultation_ids).includes(:author_user)
                                 .index_by { |r| [ r.document_type, r.document_id ] }
      signatures = Signature.where(signature_request_id: requests.values.map(&:id))
                            .select(:id, :signature_request_id, :signed_at, :last_verification, :provider)
                            .index_by(&:signature_request_id)
      documents.to_h do |document|
        key = [ DocumentTypes.db(document), document.id ]
        [ key, block(requests[key], signatures) ]
      end
    end

    def for(document) = blocks([ document ]).values.first

    # signer_name = nome cadastrado do autor (contrato §13); o do certificado
    # só no rodapé do PDF e no conteúdo.
    def block(request, signatures)
      return { mode: "manual" } unless request

      case request.status
      when "signed"
        signature = signatures[request.id]
        { mode: "digital", request_id: request.id, signature_id: signature&.id, signed_at: signature&.signed_at&.iso8601,
          signer_name: Screenings::Json.staff_name(request.author_user), verification: signature&.last_verification }
          .compact.merge(simulated: signature.present? && signature.simulated?)
      when "returned_to_paper" then { mode: "manual", request_id: request.id, reason_code: request.reason_code }
      else { mode: "pending", request_id: request.id, reason_code: request.reason_code }.compact
      end
    end
    private_class_method :block
  end
end
