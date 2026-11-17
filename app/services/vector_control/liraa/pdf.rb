# PDF do LIRAa (módulo 35a, ADR 0054; contrato §10): os índices do
# levantamento por estrato e do município (VectorControl::Reports.liraa_report,
# o mesmo do JSON e do CSV) na folha A4 de Consultations::Print.document, sem
# rodapé. Só contagens e índices: nenhum imóvel, endereço ou pessoa. Gera
# bytes; nada é gravado nem logado.
module VectorControl
  module Liraa
    module Pdf
      STATUS_LABELS = { "draft" => "rascunho", "drawn" => "sorteado", "closed" => "fechado" }.freeze

      module_function

      # -> String (bytes do PDF)
      def build(survey, report: Reports.liraa_report(survey))
        title = "LIRAa — #{survey.name}"
        pdf = Consultations::Print.document(nil, title: title)
        pdf.text s(CityProfile.current&.name.to_s), style: :bold, size: 12
        pdf.text s(title), style: :bold, size: 13
        pdf.text s("Período: #{date(survey.starts_on)} a #{date(survey.ends_on)} · situação: #{STATUS_LABELS.fetch(survey.status)}")
        pdf.text s("PROVISÓRIO: há amostra sem resultado de laboratório."), style: :bold if report[:provisional]
        report.fetch(:rows).each { |row| stratum(pdf, row) }
        Array(report[:notes]).each do |note|
          pdf.move_down 6
          pdf.text s(note), size: 9
        end
        pdf.move_down 12
        pdf.text s("Impresso em #{Time.current.strftime('%d/%m/%Y %H:%M')}."), size: 8
        pdf.render
      end

      def stratum(pdf, row)
        pdf.move_down 10
        pdf.text s(row.fetch("stratum")), style: :bold, size: 11
        pdf.text s("Amostra planejada: #{row['planned']} · inspecionados: #{row['inspected']} · substituições: " \
                   "#{row['substitutions']} · sem candidato: #{row['missing']}")
        pdf.text s("IIP: #{value(row['iip'])}% (#{row['iip_class'] || 'sem inspeção'}) · IB: #{value(row['ib'])}% · " \
                   "imóveis positivos: #{row['positive_households']} · recipientes positivos: #{row['positive_containers']}")
        itr = Catalog::DEPOSIT_GROUPS.map { |group| "#{group} #{value(row["itr_#{group}"])}%" }.join(" · ")
        pdf.text s("ITR: #{itr}")
      end

      def value(text) = text.nil? ? "—" : text.tr(".", ",")
      def date(value) = value.strftime("%d/%m/%Y")
      def s(text) = Consultations::Print.safe(text)
      private_class_method :stratum, :value, :date, :s
    end
  end
end
