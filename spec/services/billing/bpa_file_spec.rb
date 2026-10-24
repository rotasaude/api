require "rails_helper"

# Layout do BPA Magnético de 09/07/2026 (contracts/billing/bpa-interface.md):
# golden byte a byte contra os exemplos gerados pelo oráculo independente do
# repo contracts (mesmas entradas, montadas aqui em Ruby); folhas de 20;
# campo de controle; só ASCII; linhas de tamanho fixo; recusa acima de 999 folhas.
RSpec.describe Billing::BpaFile do
  FIXTURES = Rails.root.join("spec/fixtures/billing")
  HEADER = Billing::BpaFile::Header.new(competence: "202609", origin_name: "SMS Curitiba", origin_acronym: nil, origin_cnpj: "11222333000181",
                                        destination_body: "Secretaria Municipal de Saúde", management: "M")
  C_CODES = %w[0202010473 0202020380 0202010317].freeze
  PROFESSIONALS = [ %w[798312812760829 225125], %w[765218542269265 223505] ].freeze
  NAMES = [ "Maria Aparecida da Silva", "José Antônio Pereira", "Ana Lúcia D'Ávila Gonçalves", "João Batista Conceição",
            "Luíza Helena de Araújo Fontes Bittencourt" ].freeze
  CPFS = %w[29136237191 66012407106 99378987656 93842327501 96273885648 87159190726 06446750714 28441315817 74747239723
            93161173481 18425542049 10271688769 28258981714 38263611130 23441850114 22458158749 37499727378 18615318263
            05596308676 42719726737 02622189095 19833011594 74018474776 33531950410 79387458989].freeze

  def c_lines
    (0...21).map do |i|
      described_class::CLine.new(cnes: "1234567", competence: "202609", cbo: "221205", procedure: C_CODES[i % 3], age: 20 + i, quantity: i + 1)
    end
  end

  def i_lines
    (0...25).map do |j|
      on = Date.new(2026, 9, 1 + (j % 28))
      born = Date.new(1950 + j, 1 + (j % 12), 1 + (j % 27))
      cns, cbo = j < 22 ? PROFESSIONALS[0] : PROFESSIONALS[1]
      described_class::ILine.new(key: format("i%02d", j), cnes: "7654321", competence: "202609", professional_cns: cns, cbo: cbo,
                                 performed_on: on, procedure: j < 22 ? "0301010072" : "0301010048", sex: j.even? ? "F" : "M",
                                 ibge: "410690", cid10: (j % 3).zero? ? "I10" : nil, age: Citizen.age_between(born, on), quantity: 1,
                                 character: (j % 4).zero? ? "02" : "01", name: NAMES[j % 5], birth_date: born,
                                 race_color: %w[01 02 03 04 05][j % 5], ethnicity: j % 5 == 4 ? "0001" : nil,
                                 zip: j.even? ? "80010000" : "81020130", street: j.even? ? "Rua XV de Novembro" : "Av. Sete de Setembro, 2.775",
                                 number: (j % 3).zero? ? "SN" : "1200", complement: j % 4 == 1 ? "Apto 12" : nil,
                                 district: j.even? ? "Centro" : "Rebouças", phone: (j % 3).zero? ? nil : format("4199%07d", j), cpf: CPFS[j],
                                 cns: nil)
    end
  end

  def golden(name) = FIXTURES.join(name).binread

  it "BPA-C: 21 linhas em duas folhas (20 + 1), igual ao golden byte a byte" do
    built = described_class.build(header: HEADER, c_lines: c_lines.shuffle(random: Random.new(7)), i_lines: [])
    expect(built.bytes).to eq(golden("bpa-c-21-lines.txt"))
    expect(built).to have_attributes(control: 1581, lines_bpa_c: 21, lines_bpa_i: 0, sheets: 2)
  end

  it "BPA-I: folha nova a cada profissional, 20 por folha; acentos, apóstrofo e nome longo; igual ao golden" do
    built = described_class.build(header: HEADER, c_lines: [], i_lines: i_lines.reverse)
    expect(built.bytes).to eq(golden("bpa-i-25-lines.txt"))
    expect(built).to have_attributes(control: 2131, lines_bpa_i: 25, sheets: 3)
    lines = built.bytes.split("\r\n")
    expect(lines[1][44, 5]).to eq("00101")   # folha 001, linha 01 (o profissional de CNS menor)
    expect(lines[4][44, 5]).to eq("00201")
    expect(lines[24][44, 5]).to eq("00301")
    expect(lines.map { |l| l[112, 30] }.uniq).to include("LUIZA HELENA DE ARAUJO FONTES ", "ANA LUCIA D AVILA GONCALVES   ")
  end

  it "BPA-C e BPA-I no mesmo arquivo: uma série de folhas; igual ao golden" do
    built = described_class.build(header: HEADER, c_lines: c_lines.first(2), i_lines: i_lines.first(2))
    expect(built.bytes).to eq(golden("bpa-mixed.txt"))
    expect(built).to have_attributes(control: 1617, sheets: 2)
  end

  it "só ASCII imprimível, CR+LF em todo registro e tamanho fixo por tipo" do
    bytes = described_class.build(header: HEADER, c_lines: c_lines, i_lines: i_lines).bytes
    expect(bytes.bytes.reject { |b| b == 13 || b == 10 }).to all(be_between(0x20, 0x7E))
    expect(bytes).to end_with("\r\n")
    lengths = bytes.split("\r\n").group_by { |l| l[0, 2] }.transform_values { |ls| ls.map(&:length).uniq }
    expect(lengths).to eq("01" => [ 130 ], "02" => [ 48 ], "03" => [ 351 ])
  end

  it "campo de controle sempre em 1111..2221 (resto zero dá 1111)" do
    line = described_class::CLine.new(cnes: "1234567", competence: "202609", cbo: "221205", procedure: "0000001110", age: 30, quantity: 1)
    expect(described_class.build(header: HEADER, c_lines: [ line ], i_lines: []).control).to eq(1111)
    line = line.with(quantity: 1110)
    expect(described_class.build(header: HEADER, c_lines: [ line ], i_lines: []).control).to eq(2220)
  end

  it "999 folhas cabem; 1000 recusam (nunca corta)" do
    many = ->(n) { Array.new(n) { |i| described_class::CLine.new(cnes: "1234567", competence: "202609", cbo: "221205", procedure: "0202010473", age: i % 131, quantity: 1) } }
    expect(described_class.build(header: HEADER, c_lines: many.call(999 * 20), i_lines: []).sheets).to eq(999)
    expect { described_class.build(header: HEADER, c_lines: many.call(999 * 20 + 1), i_lines: []) }.to raise_error(described_class::TooManySheets, "excede 999 folhas")
  end

  it "campo que não cabe levanta ArgumentError sem o valor na mensagem" do
    bad = c_lines.first.with(cnes: "12345678")
    expect { described_class.build(header: HEADER, c_lines: [ bad ], i_lines: []) }.to raise_error(ArgumentError) { |e| expect(e.message).not_to include("12345678") }
  end

  it "inspect/to_s de ILine e Built não vazam CPF, nome, CNS nem o conteúdo do arquivo" do
    line = i_lines.first
    built = described_class.build(header: HEADER, c_lines: [], i_lines: [ line ])
    texts = [ line.inspect, line.to_s, "#{line}", built.inspect, built.to_s, PP.pp(line, +""), PP.pp(built, +"") ]
    secrets = CPFS + NAMES + PROFESSIONALS.map(&:first) + [ "RUA XV", "Rua XV" ]
    texts.each { |t| secrets.each { |v| expect(t).not_to include(v) } }
    expect(built.inspect).to include("size=#{built.bytes.bytesize}")
  end
end
