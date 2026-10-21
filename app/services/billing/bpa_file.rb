# Arquivo de interface do BPA Magnético (ADR 0039; contracts/billing/bpa-interface.md;
# Layout_Exportacao_BPA.pdf do DATASUS de 09/07/2026). Função pura: recebe o
# cabeçalho e as linhas já montadas (Billing::Lines) e devolve os bytes ASCII
# com CR+LF. Folhas numa série só: BPA-C primeiro (CBO, procedimento, idade,
# competência), depois BPA-I com folha nova a cada profissional (CNS + CBO),
# 20 linhas por folha, até 999. Campo de controle: Σ(procedimento +
# quantidade) mod 1111 + 1111. Mensagem de erro nunca cita o valor do campo.
module Billing
  module BpaFile
    SHEET_LINES = 20
    MAX_SHEETS = 999
    ORIGIN = "BPA".freeze
    VERSION = "ROTASAUDE".freeze
    WITHOUT_CPF = "N".freeze
    CRLF = "\r\n".freeze
    CHARACTER = { "elective" => "01", "urgent" => "02" }.freeze
    LENGTHS = { "01" => 130, "02" => 48, "03" => 351 }.freeze

    class TooManySheets < StandardError
      def initialize(message = "excede 999 folhas") = super
    end

    Header = Data.define(:competence, :origin_name, :origin_acronym, :origin_cnpj, :destination_body, :management)
    CLine = Data.define(:cnes, :competence, :cbo, :procedure, :age, :quantity)
    ILine = Data.define(:key, :cnes, :competence, :professional_cns, :cbo, :performed_on, :procedure, :sex, :ibge, :cid10, :age, :quantity,
                        :character, :name, :birth_date, :race_color, :ethnicity, :zip, :street, :number, :complement, :district, :phone,
                        :cpf) do
      # LGPD: nunca CPF, CNS, nome ou endereço em inspect/log.
      def inspect = "#<Billing::BpaFile::ILine key=#{key} competence=#{competence} procedure=#{procedure}>"
      alias_method :to_s, :inspect
      def pretty_print(q) = q.text(inspect) # Data#pretty_print ignora o inspect
    end
    Built = Data.define(:bytes, :control, :lines_bpa_c, :lines_bpa_i, :sheets) do
      # LGPD: o conteúdo do arquivo nunca aparece em inspect/log.
      def inspect = "#<Billing::BpaFile::Built lines_bpa_c=#{lines_bpa_c} lines_bpa_i=#{lines_bpa_i} sheets=#{sheets} control=#{control} size=#{bytes.bytesize}>"
      alias_method :to_s, :inspect
      def pretty_print(q) = q.text(inspect) # Data#pretty_print ignora o inspect
    end

    module_function

    def build(header:, c_lines:, i_lines:)
      c_sheets = c_lines.sort_by { |l| [ l.cbo, l.procedure, l.age, l.competence ] }.each_slice(SHEET_LINES).to_a
      i_sheets = i_lines.sort_by { |l| [ l.professional_cns, l.cbo, l.performed_on, l.procedure, l.key ] }
                        .chunk_while { |a, b| [ a.professional_cns, a.cbo ] == [ b.professional_cns, b.cbo ] }
                        .flat_map { |group| group.each_slice(SHEET_LINES).to_a }
      sheet = c_sheets.size + i_sheets.size
      raise TooManySheets if sheet > MAX_SHEETS

      rows = []
      c_sheets.each.with_index(1) { |slice, number| slice.each.with_index(1) { |line, seq| rows << c_row(line, number, seq) } }
      i_sheets.each.with_index(c_sheets.size + 1) { |slice, number| slice.each.with_index(1) { |line, seq| rows << i_row(line, number, seq) } }
      control = (c_lines + i_lines).sum { |l| l.procedure.to_i + l.quantity } % 1111 + 1111
      text = header_row(header, rows.size, sheet, control) + CRLF + rows.map { |row| row + CRLF }.join
      Built.new(bytes: text.encode(Encoding::US_ASCII).b, control: control, lines_bpa_c: c_lines.size, lines_bpa_i: i_lines.size, sheets: sheet)
    end

    def header_row(h, lines, sheets, control)
      fixed("01", "01" + "#BPA#" + num(h.competence, 6) + num(lines, 6) + num(sheets, 6) + num(control, 4) + text(h.origin_name, 30) +
                  text(h.origin_acronym, 6) + num(h.origin_cnpj, 14) + text(h.destination_body, 40) + alfa(h.management, 1) + alfa(VERSION, 10))
    end

    def c_row(l, sheet, seq)
      fixed("02", "02" + num(l.cnes, 7) + num(l.competence, 6) + alfa(l.cbo, 6) + num(sheet, 3) + num(seq, 2) + num(l.procedure, 10) +
                  num(l.age, 3) + num(l.quantity, 6) + alfa(ORIGIN, 3))
    end

    def i_row(l, sheet, seq)
      fixed("03", "03" + num(l.cnes, 7) + num(l.competence, 6) + num(l.professional_cns, 15) + alfa(l.cbo, 6) +
                  l.performed_on.strftime("%Y%m%d") + num(sheet, 3) + num(seq, 2) + num(l.procedure, 10) +
                  blank(15) +                                              # CNS do paciente: nunca junto do CPF
                  alfa(l.sex, 1) + opt_num(l.ibge, 6) + alfa(l.cid10, 4) + num(l.age, 3) + num(l.quantity, 6) +
                  num(l.character, 2) + blank(13) + alfa(ORIGIN, 3) +       # caráter, autorização, origem
                  text(l.name, 30) + l.birth_date.strftime("%Y%m%d") + num(l.race_color, 2) + opt_num(l.ethnicity, 4) +
                  blank(3) + blank(3) + blank(3) + blank(8) + blank(4) + blank(14) +   # nac., serviço, classif., equipe, CNPJ OPM
                  num(l.zip, 8) + blank(3) + address(l.street, 30) + address(l.complement, 10) + address(l.number, 5) +
                  address(l.district, 30) + opt_alfa_digits(l.phone, 11) + blank(40) + # bairro, telefone, e-mail
                  blank(10) + num(l.cpf, 11) + blank(1) + WITHOUT_CPF)                  # INE, CPF, situação de rua, sem CPF
    end

    def num(value, size)
      digits = value.to_s
      raise ArgumentError, "campo numérico fora do layout (#{size} posições)" unless digits.match?(/\A\d{1,#{size}}\z/)

      digits.rjust(size, "0")
    end

    def opt_num(value, size) = value.blank? ? blank(size) : num(value, size)

    def alfa(value, size)
      chars = value.to_s
      raise ArgumentError, "campo alfanumérico fora do layout (#{size} posições)" if chars.length > size || !chars.match?(/\A[ -~]*\z/)

      chars.ljust(size)
    end

    def opt_alfa_digits(value, size)
      return blank(size) if value.blank?
      raise ArgumentError, "campo numérico fora do layout (#{size} posições)" unless value.to_s.match?(/\A\d{1,#{size}}\z/)

      value.to_s.ljust(size)
    end

    # Maiúsculas ASCII, só letras e espaço, espaços colapsados (Desvio 6). Pública:
    # Billing::SaveSettings mede as larguras do cabeçalho com ela (§13 E20).
    def plain_text(value) = ActiveSupport::Inflector.transliterate(value.to_s, " ").upcase.gsub(/[^A-Z ]/, " ").squish

    # plain_text cortado no tamanho do campo.
    def text(value, size) = plain_text(value)[0, size].ljust(size)

    # Endereço (D-U1): como `text`, mas com dígitos ("RUA 7 DE SETEMBRO", "APTO 12", "1200", "SN").
    def address(value, size)
      plain = ActiveSupport::Inflector.transliterate(value.to_s, " ").upcase.gsub(/[^A-Z0-9 ]/, " ").squish
      plain[0, size].ljust(size)
    end

    def blank(size) = " " * size

    def fixed(kind, row)
      raise ArgumentError, "registro #{kind} com #{row.length} posições" unless row.length == LENGTHS.fetch(kind)

      row
    end
    private_class_method :header_row, :c_row, :i_row, :num, :opt_num, :alfa, :opt_alfa_digits, :text, :address, :blank, :fixed
  end
end
