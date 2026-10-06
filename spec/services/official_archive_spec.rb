# spec/services/official_archive_spec.rb
require "rails_helper"

# ADR 0028: o arquivo oficial chega em ZIP ou já extraído; o leitor é o mesmo.
RSpec.describe OfficialArchive do
  let(:dir) { Rails.root.join("spec/fixtures/terminology/cid10") }
  let(:tmp) { Pathname(Dir.mktmpdir) }
  after { FileUtils.remove_entry(tmp) }

  def zip_of(source)
    path = tmp.join("oficial.zip")
    Zip::File.open(path.to_s, create: true) do |zip|
      source.children.each { |file| zip.add("pasta/#{file.basename}", file.to_s) }
    end
    path
  end

  it "lê linhas por cabeçalho, da pasta e do ZIP, sem diferenciar maiúsculas no nome" do
    from_dir = []
    described_class.open(dir) { |a| a.each_row(/\Acid-10-categorias\.csv\z/i) { |row| from_dir << row } }
    from_zip = []
    described_class.open(zip_of(dir)) { |a| a.each_row(/\Acid-10-categorias\.csv\z/i) { |row| from_zip << row } }
    expect(from_dir.first).to include("CAT" => "E11", "DESCRICAO" => "Diabetes mellitus nao-insulino-dependente")
    expect(from_zip).to eq(from_dir)
  end

  it "converte ISO-8859-1 para UTF-8" do
    tmp.join("x.csv").binwrite("codigo;titulo\nK86;Hipertens\xE3o\n".b)
    rows = []
    described_class.open(tmp) { |a| a.each_row(/\Ax\.csv\z/) { |r| rows << r } }
    expect(rows).to eq([ { "CODIGO" => "K86", "TITULO" => "Hipertensão" } ])
  end

  it "sha256 estável; caminho inexistente, ZIP quebrado e arquivo ausente levantam NotFound" do
    a = described_class.open(dir, &:sha256)
    expect(described_class.open(dir, &:sha256)).to eq(a)
    expect { described_class.open(tmp.join("nada")) { nil } }.to raise_error(described_class::NotFound)
    tmp.join("ruim.zip").write("não é zip")
    expect { described_class.open(tmp.join("ruim.zip")) { nil } }.to raise_error(described_class::NotFound)
    expect { described_class.open(dir) { |x| x.each_row(/\Aoutro\.csv\z/) { nil } } }.to raise_error(described_class::NotFound)
  end

it "linha acima do teto levanta LineTooLong sem ler o arquivo todo" do
  tmp.join("x.csv").binwrite("codigo;titulo
" + ("a" * (described_class::MAX_LINE_BYTES + 10)))
  expect { described_class.open(tmp) { |a| a.each_row(/\Ax\.csv\z/) { nil } } }.to raise_error(described_class::LineTooLong)
end

it "aceita linha exatamente no teto" do
  tmp.join("x.csv").binwrite("codigo;titulo\nK86;" + ("a" * (described_class::MAX_LINE_BYTES - 5)) + "\n")
  rows = []
  described_class.open(tmp) { |a| a.each_row(/\Ax\.csv\z/) { |r| rows << r } }
  expect(rows.size).to eq(1)
end

it "erro de ZIP no meio da leitura sobe como Zip::Error, não como NotFound" do
  path = tmp.join("corrompido.zip")
  Zip::File.open(path.to_s, create: true) { |z| z.get_output_stream("ciap2.csv") { |o| o.write("codigo;titulo\n" + "K86;Hipertensao\n" * 500) } }
  bytes = path.binread
  bytes[60, 40] = "\x00" * 40
  path.binwrite(bytes)
  expect { described_class.open(path) { |a| a.each_row(/\Aciap2\.csv\z/, encoding: "UTF-8") { nil } } }
    .to raise_error(Zip::Error)
end
end
