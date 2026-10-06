require "rails_helper"

# Review Focus 3: last_error nunca guarda dado de cidadão.
RSpec.describe Ledi::ErrorText do
  {
    "CPF 12345678909 inválido" => "CPF [número] inválido",
    "CNS do cidadão 898001160660761 não encontrado" => "CNS do cidadão [número] não encontrado",
    "CNES 1234567 não pertence ao município" => "CNES 1234567 não pertence ao município",
    "  INE   0000123456 inativo \n" => "INE 0000123456 inativo",
    "telefone 41999990000" => "telefone [número]",
    "CPF 123.456.789-09 inválido" => "CPF [número] inválido",
    "cartão 700 0000 0000 0005 x" => "cartão [número] x",
    "CNPJ 12.345.678/0001-95 x" => "CNPJ [número] x",
    "em 2026-10-06 CNES 1234567 INE 0000123456" => "em 2026-10-06 CNES 1234567 INE 0000123456"
  }.each do |input, expected|
    it(input.strip.inspect) { expect(described_class.sanitize(input)).to eq(expected) }
  end

  it "corta em 500 caracteres e trata nil" do
    expect(described_class.sanitize("x" * 900).length).to eq(500)
    expect(described_class.sanitize(nil)).to eq("")
  end
end
