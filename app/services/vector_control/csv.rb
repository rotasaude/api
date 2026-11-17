# CSV dos relatórios da vigilância ambiental (módulo 35a, ADR 0054; contrato
# §10): o VectorReport (VectorControl::Reports) como tabela, no molde do
# Surveillance::Csv — UTF-8 com BOM, `;` e `\r\n` (Excel pt-BR), cabeçalho
# com os rótulos das colunas em português. Contagem suprimida sai "< 5";
# percentual e decimal com vírgula; nil vazio. As notas do relatório saem no
# fim, depois de uma linha em branco, uma por linha numa célula só. Toda
# célula passa por Exams::Report.safe_cell (injeção de fórmula).
require "csv"

module VectorControl
  module Csv
    SUPPRESSED = "< 5".freeze

    module_function

    # report: o hash do Reports.build -> String
    def build(report)
      columns = report.fetch(:columns)
      text = CSV.generate(col_sep: Surveillance::Csv::SEPARATOR, row_sep: "\r\n") do |csv|
        csv << columns.map { |column| Exams::Report.safe_cell(column.fetch(:label)) }
        report.fetch(:rows).each do |row|
          csv << columns.map { |column| Exams::Report.safe_cell(cell(row[column.fetch(:key)], column.fetch(:kind))) }
        end
        notes = Array(report[:notes])
        csv << [] if notes.any?
        notes.each { |note| csv << [ Exams::Report.safe_cell(note) ] }
      end
      Surveillance::Csv::BOM + text
    end

    def cell(value, kind)
      return SUPPRESSED if value == Admin::SmallCount::SUPPRESSED
      return nil if value.nil?

      %w[percent decimal].include?(kind) ? value.to_s.tr(".", ",") : value
    end
    private_class_method :cell
  end
end
