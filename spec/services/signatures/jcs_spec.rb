require "rails_helper"

# RFC 8785 (JCS): os vetores do próprio RFC (§3.2.2 números, §3.2.3 ordem das
# chaves) e as recusas.
RSpec.describe Signatures::Jcs do
  it "números na forma do ECMAScript (RFC 8785 §3.2.2.3)" do
    expect(described_class.dump([ 333_333_333.33333329, 1e30, 4.50, 2e-3, 0.000000000000000000000000001 ]))
      .to eq("[333333333.3333333,1e+30,4.5,0.002,1e-27]")
    expect(described_class.dump([ 0.0, -0.0, 1e21, 1e20, 1e-7, 0.00001, 82.5, BigDecimal("36.7"), 10, -3 ]))
      .to eq("[0,0,1e+21,100000000000000000000,1e-7,0.00001,82.5,36.7,10,-3]")
    expect(described_class.dump([ 100.0, -1.5, 9_007_199_254_740_991, -9_007_199_254_740_991, 123.456e-10 ]))
      .to eq("[100,-1.5,9007199254740991,-9007199254740991,1.23456e-8]")
  end

  # A chave hebraica é U+FB33 (forma de apresentação, como no RFC): escrita
  # por escape para não virar a forma decomposta U+05D3 U+05BC no editor.
  it "ordena as chaves por unidades UTF-16 (RFC 8785 §3.2.3)" do
    input = { "€" => "Euro Sign", "\r" => "Carriage Return", "\u{FB33}" => "Hebrew Letter Dalet With Dagesh",
              "1" => "One", "\u{1F600}" => "Emoji: Grinning Face", "\u0080" => "Control", "ö" => "Latin Small Letter O With Diaeresis" }
    expect(JSON.parse(described_class.dump(input)).keys).to eq([ "\r", "1", "\u0080", "ö", "€", "\u{1F600}", "\u{FB33}" ])
    expect(described_class.dump({ "b" => [ true, false, nil ], "a" => { "d" => 1, "c" => "x" } })).to eq('{"a":{"c":"x","d":1},"b":[true,false,null]}')
  end

  it "escapa só o obrigatório; o resto vai literal" do
    expect(described_class.dump("aspas \" barra \\ / linha\n tab\t \u000f é ≥ 😷 \u007f "))
      .to eq("\"aspas \\\" barra \\\\ / linha\\n tab\\t \\u000f é ≥ 😷 \u007f \"")
  end

  it "aceita texto ASCII em outra codificação (ex.: Time#iso8601) e devolve UTF-8" do
    out = described_class.dump({ "t" => "2026-10-09T12:00:00Z".encode("US-ASCII") })
    expect(out).to eq('{"t":"2026-10-09T12:00:00Z"}')
    expect(out.encoding).to eq(Encoding::UTF_8)
  end

  it "recusa o que o JSON canônico não representa" do
    [ Float::NAN, Float::INFINITY, 2**53, -(2**53), Object.new, Date.new(2026, 1, 1), :symbol, { a: 1, "a" => 2 },
      { 1 => "x" }, "\xFF".dup.force_encoding("UTF-8"), "\xC3".b ].each do |value|
      expect { described_class.dump(value) }.to raise_error(described_class::Unsupported), value.inspect
    end
  end
end
