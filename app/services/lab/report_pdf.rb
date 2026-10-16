# PDF do laudo (RDC 978 art. 167; spec §5.7), gerado do JSON congelado:
# I–II laboratório, CNES, endereço, telefone; III RT; IV quem libera; V–VI
# paciente, registro, nascimento; VII coleta; VIII exame, material, método;
# IX valor e unidade; X referência; XII restrição; XIII emissão; XIV
# assinatura (avançada: bloco no corpo; ICP: rodapé NGS2 do 19b). QR e código
# da conferência pública (19c). XI (metodologia própria) não se aplica.
# Texto longo quebra de linha (nunca sai da página); cada linha de componente
# tem a altura da maior célula e não parte entre páginas.
module Lab
  module ReportPdf
    FLAGS = { "low" => "BAIXO", "high" => "ALTO", "critical_low" => "CRÍTICO BAIXO", "critical_high" => "CRÍTICO ALTO" }.freeze
    QR_SIZE = 84
    NAME_W = 180
    VALUE_W = 150

    module_function

    def call(report, footer: nil)
      c = report.content_data
      pdf = Consultations::Print.document(footer, title: "Laudo laboratorial")
      header(pdf, c, report)
      patient(pdf, c)
      c["exams"].each { |exam| exam(pdf, exam) }
      signers(pdf, c, footer)
      verification(pdf, report)
      pdf.render
    end

    def s(text) = Consultations::Print.safe(text)
    def date(iso) = Date.iso8601(iso).strftime("%d/%m/%Y")
    def time(iso) = Time.iso8601(iso).in_time_zone.strftime("%d/%m/%Y %H:%M")
    def phone(value) = value.to_s.sub(/\A(\d{2})(\d{4,5})(\d{4})\z/, '(\1) \2-\3')
    def council(p) = "#{p['council']}-#{p['council_uf']} #{p['council_number']}"

    def header(pdf, c, report)
      lab = c["laboratory"]
      pdf.text s(lab["name"]), style: :bold, size: 12
      pdf.text s("CNES #{lab['cnes']} — #{lab['address']} — Telefone #{phone(lab['phone'])}"), size: 9
      pdf.move_down 8
      title = "LAUDO DE EXAMES LABORATORIAIS"
      title += " — LAUDO PARCIAL" if c["partial"]
      pdf.text s(title), style: :bold, size: 13
      if c["replaces_report_id"]
        pdf.text s("RETIFICAÇÃO — substitui o laudo anterior. Motivo: #{c['rectification_reason']}"), style: :bold
      end
      pdf.text s("Laudo versão #{report.version} — Emitido em #{time(c['issued_at'])}"), size: 9
    end

    def patient(pdf, c)
      p = c["patient"]
      pdf.move_down 8
      pdf.text s("Paciente: #{p['name']}"), style: :bold
      birth = p["birth_date"] ? date(p["birth_date"]) : "não informado"
      sex = p["biological_sex"] == "female" ? "feminino" : "masculino"
      pdf.text s("Registro #{p['record_number']} — Nascimento: #{birth} — Sexo biológico: #{sex}")
    end

    def exam(pdf, exam)
      pdf.move_down 10
      pdf.start_new_page if pdf.cursor < 60
      pdf.text s(exam["name"]), style: :bold, size: 11
      pdf.text s("Material: #{exam['material']} — Método: #{exam['method']} — Coleta: #{time(exam['collected_at'])} — Versão do exame #{exam['version']}"), size: 9
      pdf.text s("Amostra aceita com restrição: #{exam['restriction_note']}"), size: 9, style: :italic if exam["restriction_note"]
      pdf.move_down 2
      exam["components"].each { |comp| component(pdf, comp) }
    end

    def component(pdf, comp)
      value = [ comp["value"], comp["unit"] ].compact.join(" ")
      mark = FLAGS[comp["flag"]]
      cells = [ [ s(comp["name"]), NAME_W, 10, :normal ],
                [ s("#{value}#{mark ? "  (#{mark})" : ''}"), VALUE_W, 10, mark ? :bold : :normal ],
                [ s(comp["reference_text"] ? "Referência: #{comp['reference_text']}" : ""), pdf.bounds.width - NAME_W - VALUE_W, 8, :normal ] ]
      height = cells.map { |text, width, size, style| pdf.height_of(text, width: width - 4, size: size, style: style) }.max
      pdf.start_new_page if pdf.cursor < height + 4
      top = pdf.cursor
      x = 0
      cells.each do |text, width, size, style|
        pdf.text_box text, at: [ x, top ], width: width - 4, height: height, size: size, style: style
        x += width
      end
      pdf.move_down height + 3
    end

    def signers(pdf, c, footer)
      pdf.move_down 12
      pdf.start_new_page if pdf.cursor < 70
      pdf.text s("Responsável técnico: #{c.dig('technical_lead', 'name')} — #{council(c['technical_lead'])}"), size: 9
      pdf.text s("Liberado por: #{c.dig('released_by', 'name')} — #{council(c['released_by'])}"), size: 9
      if c["signature_kind"] == "advanced"
        pdf.text s("Assinado com assinatura eletrônica avançada (Lei 14.063/2020; RDC 978/2025, art. 5º, III) por " \
                   "#{c.dig('released_by', 'name')}, #{council(c['released_by'])}, em #{time(c['issued_at'])}."), size: 9
      elsif footer.nil?
        pdf.text s("Assinatura digital ICP-Brasil pendente."), size: 9
      else
        pdf.text s("Assinado digitalmente (ICP-Brasil) — ver rodapé."), size: 9
      end
    end

    def verification(pdf, report)
      pdf.start_new_page if pdf.cursor < QR_SIZE + 20
      pdf.move_down 12
      top = pdf.cursor
      url = "#{CityPublicUrl.base(Current.city)}/v/#{report.verification_token}"
      ClinicalDocuments::Qr.draw(pdf, url, at: [ 0, top ], size: QR_SIZE)
      pdf.bounding_box([ QR_SIZE + 10, top - 10 ], width: pdf.bounds.width - QR_SIZE - 10) do
        pdf.text s("Confira a autenticidade deste laudo:"), size: 9
        pdf.text s(url), size: 8
        pdf.text s("ou em #{CityPublicUrl.base(Current.city)}/v com o código #{ClinicalDocuments::Codes.display(report.short_code)} e o ano de nascimento do paciente."), size: 9
      end
    end
    private_class_method :s, :date, :time, :phone, :council, :header, :patient, :exam, :component, :signers, :verification
  end
end
