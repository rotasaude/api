require "rails_helper"
require "pdf/reader"

# Review Focus 5 (etiqueta no limite) e Valores fixados 4: 50 x 25 mm, uma
# por página, Code 128 de 10 dígitos com zona de silêncio, texto fora da barra.
RSpec.describe Lab::LabelsPdf do
  before { lab_city! }

  let(:provider) { lab_provider! }
  let(:req) { open_requisition!(provider: provider, exams: [ lab_exam!(provider: provider) ]) }

  it "uma etiqueta por página, no tamanho do tubo, com o número e os quatro campos" do
    req.patient.update!(full_name: "JOSÉ DE ASSUNÇÃO PEREIRA DOS SANTOS ALBUQUERQUE NETO DA CONCEIÇÃO E SILVA FILHO", birth_date: nil)
    sample = req.samples.first
    reader = PDF::Reader.new(StringIO.new(described_class.call([ sample, sample ])))
    expect(reader.page_count).to eq(2)
    expect(reader.pages.first.attributes[:MediaBox].map { |n| n.round(2) }).to eq([ 0, 0, 141.73, 70.87 ])
    text = reader.pages.first.text
    expect(text).to include(sample.barcode, "Req. #{req.number}", "Nasc. não informado", "Plasma")
    expect(text).to include("JOSÉ DE ASSUNÇÃO")
    # B23: o nome que não cabe é cortado COM reticências; código e número nunca.
    expect(text).to include("…")
    expect(text).not_to include("CONCEIÇÃO E SILVA FILHO")
    # um retângulo por sequência de módulos escuros: a barra desenhada é o código inteiro
    expect(reader.pages.first.raw_content.scan(/\bre\b/).size).to eq(Lab::Code128.encoding(sample.barcode).scan(/1+/).size)
  end

  it "nome que cabe não leva reticências; código e número inteiros" do
    req.patient.update!(full_name: "ANA LIMA")
    sample = req.samples.first
    text = PDF::Reader.new(StringIO.new(described_class.call([ sample ]))).pages.first.text
    expect(text).to include("ANA LIMA", sample.barcode, "Req. #{req.number}")
    expect(text).not_to include("…")
  end

  it "a codificação é a do conjunto C da barby para os dígitos do código" do
    sample = req.samples.first
    expect(Lab::Code128.encoding(sample.barcode)).to eq(Barby::Code128C.new(sample.barcode).encoding)
  end

  it "o código cabe com as zonas de silêncio; só dígitos e comprimento par" do
    bars = Lab::Code128.encoding("9999999999")
    expect(bars.length).to eq(90)
    expect((bars.length + (2 * described_class::QUIET)) * described_class::MODULE).to be <= described_class::WIDTH
    expect { Lab::Code128.encoding("12345") }.to raise_error(ArgumentError)
    expect { Lab::Code128.encoding("12ab") }.to raise_error(ArgumentError)
    expect(LabSample.barcode_for("00000123", 99)).to eq("0000012399")
    expect { LabSample.barcode_for("00000123", 100) }.to raise_error(ArgumentError)
  end
end
