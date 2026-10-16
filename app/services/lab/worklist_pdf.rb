# Mapa de trabalho em PDF (spec §5.5): A4 paisagem, um bloco por setor e
# bancada, uma linha por item com espaço para anotar o valor.
module Lab
  module WorklistPdf
    SECTORS = { "biochemistry" => "Bioquímica", "hematology" => "Hematologia", "immunology" => "Imunologia",
                "urinalysis" => "Urinálise", "parasitology" => "Parasitologia", "microbiology" => "Microbiologia" }.freeze
    COLUMNS = [ [ "Req.", 60 ], [ "Código", 70 ], [ "Paciente", 220 ], [ "Exame", 170 ], [ "Recebida", 80 ], [ "Urg.", 30 ], [ "Resultado", 130 ] ].freeze

    module_function

    def call(groups, provider:, now: Time.current)
      s = ->(text) { Consultations::Print.safe(text) }
      pdf = Prawn::Document.new(page_size: "A4", page_layout: :landscape, margin: 30, info: { Title: "Mapa de trabalho", Producer: "Rota Saúde" })
      pdf.font_size(9)
      pdf.text s.call("#{provider.name} — Mapa de trabalho — #{now.in_time_zone.strftime('%d/%m/%Y %H:%M')}"), style: :bold, size: 12
      groups.each do |group|
        pdf.move_down 10
        pdf.text s.call("#{SECTORS.fetch(group[:sector], group[:sector])}#{group[:bench] ? " — #{group[:bench]}" : ''}"), style: :bold
        row(pdf, COLUMNS.map(&:first), bold: true)
        group[:items].each do |item|
          received = item[:received_at] && Time.iso8601(item[:received_at]).in_time_zone.strftime("%d/%m %H:%M")
          row(pdf, [ item[:requisition_number], item[:barcode], s.call(item[:patient_display_name]), s.call(item[:label]), received.to_s,
                     item[:urgent] ? "SIM" : "", "" ])
        end
      end
      pdf.render
    end

    def row(pdf, cells, bold: false)
      pdf.start_new_page if pdf.cursor < 20
      top = pdf.cursor
      x = 0
      COLUMNS.each_with_index do |(_, width), i|
        pdf.text_box cells[i].to_s, at: [ x, top ], width: width - 4, height: 14, overflow: :shrink_to_fit, style: bold ? :bold : :normal
        x += width
      end
      pdf.stroke_horizontal_line 0, x, at: top - 14
      pdf.move_down 16
    end
    private_class_method :row
  end
end
