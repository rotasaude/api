require "rails_helper"

# Módulo 33 (Q8; contrato §16): contagem em code points DEPOIS do strip, e o
# que se grava é o valor sem as bordas.
RSpec.describe Ombudsman::Input do
  let(:catalog) { Ombudsman::Catalog }

  it "19 caracteres com espaços ao redor: recusado (BODY 20..4000)" do
    expect(described_class.text("  #{'a' * 19}  ", catalog::BODY)).to be_nil
    expect(described_class.valid_text?("  #{'a' * 19}  ", catalog::BODY)).to be(false)
  end

  it "20 caracteres com espaços ao redor: aceito, e devolve o valor sem as bordas" do
    expect(described_class.text("\n  #{'a' * 20} \t", catalog::BODY)).to eq("a" * 20)
  end

  it "'ação' conta 4 code points" do
    expect(described_class.text("ação", 4..4)).to eq("ação")
    expect(described_class.text("ação", 5..9)).to be_nil
  end

  it "4000 caracteres multibyte são aceitos; 4001 não" do
    expect(described_class.text("ã" * 4000, catalog::BODY)).to eq("ã" * 4000)
    expect(described_class.text("ã" * 4001, catalog::BODY)).to be_nil
  end

  it "só espaços ou valor que não é String: recusado" do
    expect(described_class.text(" " * 30, catalog::TEXT)).to be_nil
    [ nil, 12, [ "texto longo o bastante" ], { a: 1 } ].each { |value| expect(described_class.text(value, catalog::TEXT)).to be_nil }
  end

  it "os intervalos dos textos são os do catálogo (TEXT 10..4000, JUSTIFICATION 10..500, REOPEN_REASON 10..2000)" do
    expect(described_class.text("a" * 9, catalog::TEXT)).to be_nil
    expect(described_class.text("a" * 10, catalog::JUSTIFICATION)).to eq("a" * 10)
    expect(described_class.text("a" * 501, catalog::JUSTIFICATION)).to be_nil
    expect(described_class.text("a" * 2000, catalog::REOPEN_REASON)).to eq("a" * 2000)
    expect(described_class.text("a" * 2001, catalog::REOPEN_REASON)).to be_nil
  end
end
