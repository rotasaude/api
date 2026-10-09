# app/services/signatures/print_report.rb
# O impresso da consulta (Desvio 13): consulta digital sem adendo → o próprio
# PAdES; com alguma parte assinada ou pendente → o impresso do 19a com a seção
# "Assinaturas" (NGS2.03.01/06.06: o estado sai na impressão) e espaço à mão
# se alguma parte não é digital ou a validação dela não é `valid` (R22); nenhum pedido → o impresso do 19a, igual.
module Signatures
  module PrintReport
    VERIFICATION = { "valid" => "válida", "invalid" => "inválida", "indeterminate" => "indeterminada" }.freeze

    Report = Data.define(:lines, :hand_signature) do
      def hand_signature? = hand_signature
    end

    module_function

    # Só o PAdES puro quando a consulta é digital, sem adendo, e a revalidação
    # dá `valid` (R21); inválida/indeterminada → o impresso com o estado.
    def signed_pdf(consultation)
      return nil if consultation.addenda.exists?

      request = SignatureRequest.find_by(document_type: "Consultation", document_id: consultation.id, status: "signed")
      return nil unless request&.signature

      signature = Verify.call(request.signature)
      signature.last_verification == "valid" ? signature.signed_pdf_bytes : nil
    end

    def for(consultation)
      return nil unless SignatureRequest.exists?(consultation_id: consultation.id)

      Signature.where(signature_request_id: SignatureRequest.where(consultation_id: consultation.id, status: "signed").select(:id))
               .find_each { |signature| Verify.call(signature) }
      addenda = consultation.addenda.order(:created_at, :id).to_a
      blocks = Mode.blocks([ consultation, *addenda ])
      parts = [ [ "Consulta", blocks[[ "Consultation", consultation.id ]] ] ] +
              addenda.map { |a| [ "Adendo de #{a.created_at.in_time_zone.strftime('%d/%m/%Y %H:%M')}", blocks[[ "ConsultationAddendum", a.id ]] ] }
      Report.new(lines: parts.map { |label, block| "#{label}: #{describe(block)}" },
                 hand_signature: parts.any? { |_label, block| block[:mode] != "digital" || block[:verification] != "valid" })
    end

    def describe(block)
      case block[:mode]
      when "digital"
        "assinada digitalmente#{' (simulada — sem validade jurídica)' if block[:simulated]} por #{block[:signer_name]} em " \
          "#{Time.iso8601(block[:signed_at]).in_time_zone.strftime('%d/%m/%Y %H:%M')} — validação " \
          "#{VERIFICATION.fetch(block[:verification].to_s, block[:verification].to_s)}"
      when "pending" then "assinatura digital pendente — assinar à mão"
      else "sem assinatura digital — assinar à mão"
      end
    end
    private_class_method :describe
  end
end
