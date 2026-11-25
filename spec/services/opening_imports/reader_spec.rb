require "rails_helper"

# Módulo 27b, Task 14 (Valor 11; Review Focus 5): a leitura da planilha do
# saldo inicial. UTF-8 (BOM aceito), `;`, CRLF ou LF, aspas RFC 4180, linha em
# branco ignorada; Latin-1, cabeçalho diferente ou coluna a menos recusam o
# arquivo inteiro (`invalid_file`); mais de 5 MB decodificados → `file_too_large`.
RSpec.describe OpeningImports::Reader, type: :service do
  let(:dir) { Rails.root.join("spec/fixtures/opening_imports") }
  let(:header) { "cnes;tipo_produto;codigo_produto;ampp;lote;validade;quantidade;valor_unitario;cnpj_fabricante;registro_anvisa;programa" }

  def read(name) = described_class.call(File.binread(dir.join(name)))

  it "o excel.csv (BOM, CRLF, `;` entre aspas, 1.234,56, linha vazia no fim) dá as linhas do ok.csv" do
    ok = read("ok.csv")
    excel = read("excel.csv")

    expect(ok).to be_ok
    expect(excel).to be_ok
    expect(excel.payload[:rows]).to eq(ok.payload[:rows])
    expect(ok.payload[:rows].map { |row| row.slice(:line, :lote, :valor_unitario, :cnpj_fabricante) })
      .to eq([ { line: 2, lote: "LOS-1", valor_unitario: "1.234,56", cnpj_fabricante: "11222333000181" },
               { line: 3, lote: "LOS;2", valor_unitario: "0,25", cnpj_fabricante: nil },
               { line: 4, lote: "VAC-9", valor_unitario: "12,00", cnpj_fabricante: "11222333000181" } ])
    expect(ok.payload[:rows].first.keys).to eq(%i[line] + described_class::HEADER.map(&:to_sym))
  end

  it "latin1.csv → invalid_file, sem linha nenhuma" do
    result = read("latin1.csv")
    expect(result).to be_failure
    expect([ result.reason, result.details ]).to eq([ :invalid_file, { path: "file_base64" } ])
  end

  it "coluna a menos (ou a mais) → invalid_file" do
    short = "#{header}\n2384299;medicamento;268856;;LOS-1;2027-06-30;100;1,00;;\n"
    long = "#{header}\n2384299;medicamento;268856;;LOS-1;2027-06-30;100;1,00;;;;AFB\n"
    expect(described_class.call(short).reason).to eq(:invalid_file)
    expect(described_class.call(long).reason).to eq(:invalid_file)
  end

  it "cabeçalho diferente, aspas quebradas ou só o cabeçalho → invalid_file" do
    expect(described_class.call(header.sub("lote", "Lote") + "\n").reason).to eq(:invalid_file)
    expect(described_class.call("#{header}\n\"2384299;medicamento\n").reason).to eq(:invalid_file)
    expect(described_class.call("#{header}\n").reason).to eq(:invalid_file)
  end

  it "5 MB + 1 byte → file_too_large" do
    bytes = "#{header}\n".ljust(described_class::MAX_BYTES + 1, "x")
    result = described_class.call(bytes)
    expect([ result.reason, result.details ]).to eq([ :file_too_large, { path: "file_base64" } ])
  end

  it "mais de 20.000 linhas → file_too_large" do
    line = "2384299;medicamento;268856;;L;2027-06-30;1;;;;\n"
    result = described_class.call("#{header}\n" + (line * (described_class::MAX_ROWS + 1)))
    expect(result.reason).to eq(:file_too_large)
  end
end
