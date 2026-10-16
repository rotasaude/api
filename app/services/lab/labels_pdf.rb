# Etiqueta de tubo (spec §5.1; RDC 978 art. 138; Valores fixados 4): 50 x 25
# mm, uma por página (impressora térmica), Code 128 em vetor com zona de
# silêncio, o código legível, nome, nascimento, material/recipiente e número
# da requisição. Nome e material que não cabem são cortados COM reticências
# (B23); o código de barras e o número da requisição nunca são cortados.
require "prawn"

module Lab
  module LabelsPdf
    MM = 72.0 / 25.4
    WIDTH = 50 * MM
    HEIGHT = 25 * MM
    MODULE = 72.0 * 3 / 203
    BAR_HEIGHT = 9 * MM
    QUIET = 10
    TOP = HEIGHT - (2 * MM)

    module_function

    def call(samples)
      pdf = Prawn::Document.new(page_size: [ WIDTH, HEIGHT ], margin: 0, info: { Title: "Etiquetas", Producer: "Rota Saúde" })
      samples.each_with_index do |sample, index|
        pdf.start_new_page if index.positive?
        label(pdf, sample)
      end
      pdf.render
    end

    def label(pdf, sample)
      bars(pdf, Code128.encoding(sample.barcode))
      req = sample.lab_requisition
      patient = req.patient
      birth = patient.birth_date.present? ? Date.iso8601(patient.birth_date).strftime("%d/%m/%Y") : "não informado"
      y = TOP - BAR_HEIGHT - 1
      pdf.text_box sample.barcode, at: [ 0, y ], width: WIDTH, height: 8, size: 7, align: :center
      max = WIDTH - (4 * MM)
      [ [ patient.display_name.to_s, true ], [ "Nasc. #{birth}", false ], [ "#{sample.material} / #{sample.container}", true ],
        [ "Req. #{req.number}", false ] ].each_with_index do |(text, ellipsize), i|
        pdf.font_size(6.5) do
          line = Consultations::Print.safe(text)
          line = ellipsis(pdf, line, max) if ellipsize
          pdf.text_box line, at: [ 2 * MM, y - 8 - (i * 7) ], width: max + 2, height: 7, overflow: :truncate
        end
      end
    end

    # Corta por largura medida, deixando "…" no fim; o que cabe passa intacto.
    def ellipsis(pdf, text, max)
      return text if pdf.width_of(text) <= max

      text = text[0...-1] while text.length.positive? && pdf.width_of("#{text.rstrip}…") > max
      "#{text.rstrip}…"
    end

    # Uma barra por sequência de módulos escuros (sem frestas entre módulos).
    def bars(pdf, encoding)
      x = (WIDTH - (encoding.length * MODULE)) / 2
      pdf.fill_color "000000"
      encoding.scan(/1+|0+/).each do |run|
        pdf.fill_rectangle([ x, TOP ], run.length * MODULE, BAR_HEIGHT) if run.start_with?("1")
        x += run.length * MODULE
      end
    end
    private_class_method :label, :bars, :ellipsis
  end
end
