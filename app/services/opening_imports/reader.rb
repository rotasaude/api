require "csv"

# Leitura da planilha do saldo inicial (módulo 27b; contrato §5; Valor 11;
# Review Focus 5). Puro: sem banco.
#
# CSV UTF-8 (o BOM do Excel é aceito), separado por `;`, CRLF ou LF, aspas RFC
# 4180, com o cabeçalho exato de HEADER. Linha em branco (vazia ou só `;`) é
# ignorada. Arquivo que não é UTF-8 (o Latin-1 do Excel antigo), cabeçalho
# diferente, aspas quebradas, linha com coluna a menos ou a mais, ou nenhuma
# linha de dados → `invalid_file`, o arquivo inteiro (sem área de
# conferência). Acima de 5 MB ou de 20.000 linhas → `file_too_large`.
#
# Cada linha: `{ line:, cnes:, tipo_produto:, … }` (as onze colunas como
# texto, sem os espaços das pontas; vazio = nil). `line` é a linha da planilha
# (o cabeçalho é a 1).
module OpeningImports
  module Reader
    HEADER = %w[cnes tipo_produto codigo_produto ampp lote validade quantidade valor_unitario cnpj_fabricante registro_anvisa
                programa].freeze
    COLUMNS = HEADER.map(&:to_sym).freeze
    MAX_BYTES = 5 * 1024 * 1024
    MAX_ROWS = 20_000
    BOM = "﻿".freeze
    PATH = "file_base64".freeze

    module_function

    # -> Result.ok(rows:) | fail(:invalid_file | :file_too_large, details: { path: "file_base64" })
    def call(bytes)
      return refuse(:invalid_file) unless bytes.is_a?(String)
      return refuse(:file_too_large) if bytes.bytesize > MAX_BYTES

      text = bytes.dup.force_encoding(Encoding::UTF_8)
      return refuse(:invalid_file) unless text.valid_encoding? && !text.include?("\u0000")

      table = CSV.parse(text.delete_prefix(BOM), col_sep: ";", quote_char: '"', row_sep: :auto)
      return refuse(:invalid_file) unless table.first == HEADER

      rows = []
      table.drop(1).each_with_index do |fields, index|
        next if fields.all? { |field| field.to_s.strip.empty? }
        return refuse(:invalid_file) unless fields.size == HEADER.size
        return refuse(:file_too_large) if rows.size == MAX_ROWS

        rows << { line: index + 2 }.merge(COLUMNS.zip(fields.map { |field| field.to_s.strip.presence }).to_h)
      end
      return refuse(:invalid_file) if rows.empty?

      Result.ok(rows: rows)
    rescue CSV::MalformedCSVError
      refuse(:invalid_file)
    end

    def refuse(reason) = Result.fail(reason, details: { path: PATH })

    private_class_method :refuse
  end
end
