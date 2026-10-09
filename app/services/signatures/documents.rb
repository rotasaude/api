# app/services/signatures/documents.rb
# Os dois documentos de cada pedido (ADR 0032; spec §7): o JSON canônico (vai
# ao CAdES destacado) e o PDF com o rodapé NGS2 (vai ao PAdES). O rodapé leva o
# nome e o CPF do CERTIFICADO, que é o que se assina; com o PSC simulado
# (ADR 0032, revisão), o aviso "simulada — sem validade jurídica".
module Signatures
  module Documents
    Prepared = Data.define(:request, :canonical, :pdf) do
      def inspect = "#<Signatures::Documents::Prepared #{request.id}>"
      alias_method :to_s, :inspect
      def pretty_print(pp) = pp.text(inspect)
    end

    module_function

    # chain: os hashes canônicos dos documentos já preparados NESTE lote
    # (Canonical.previous_sha256 os conta como assinados).
    def for(request, info:, signed_at:, chain: {}, simulated: false)
      document = request.document
      raise Canonical::Invalid, "documento não encontrado" unless document

      footer = PdfFooter.new(signer_name: info.holder_name, signer_cpf: info.cpf, signed_at: signed_at, simulated: simulated)
      case document
      when Consultation
        Prepared.new(request: request, canonical: Canonical.consultation(document),
                     pdf: Consultations::Print.call(document, footer: footer, addenda: false))
      when ConsultationAddendum
        Prepared.new(request: request, canonical: Canonical.addendum(document, chain: chain),
                     pdf: Consultations::Print.addendum(document, footer: footer))
      end
    end
  end
end
