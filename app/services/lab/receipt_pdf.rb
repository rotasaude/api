# Comprovante de atendimento (RDC 978 art. 137): número, nome, data, data
# prevista de entrega, exames, preparo e contato do laboratório. A4.
module Lab
  module ReceiptPdf
    module_function

    def call(req)
      provider = req.exam_provider
      s = ->(text) { Consultations::Print.safe(text) }
      pdf = Consultations::Print.document(nil, title: "Comprovante de atendimento")
      pdf.text s.call(provider.name), style: :bold, size: 12
      pdf.text s.call([ provider.address, provider.phone && "Telefone #{provider.phone}", provider.cnes && "CNES #{provider.cnes}" ].compact.join(" — "))
      pdf.move_down 10
      pdf.text "COMPROVANTE DE ATENDIMENTO", style: :bold, size: 13
      pdf.text s.call("Requisição nº #{req.number} — #{req.created_at.in_time_zone.strftime('%d/%m/%Y %H:%M')}")
      pdf.text s.call("Paciente: #{req.patient.display_name}")
      pdf.text s.call("Resultado previsto para: #{req.expected_delivery_on.strftime('%d/%m/%Y')}"), style: :bold
      pdf.move_down 8
      req.items.select(&:active?).each do |item|
        exam = item.lab_exam_version.lab_exam
        preparation = exam.lab_exam_template_id && LabExamTemplate.find_by(id: exam.lab_exam_template_id)&.preparation
        pdf.text s.call("• #{exam.name} (#{item.lab_exam_version.material})#{preparation ? " — preparo: #{preparation}" : ''}")
      end
      pdf.move_down 10
      pdf.text s.call("Retire o resultado com este comprovante e um documento com foto."), size: 9
      pdf.render
    end
  end
end
