require "rails_helper"

# Módulo 31 (contrato §6, P15; plano, Desvio 9): o gerador da remessa RAAS é
# puro e fica atrás do registro de layouts, que entra vazio até o gate.
RSpec.describe Psychosocial::RaasFile do
  let(:layout) do
    described_class::Layout.new(version: "test-1",
                                writer: ->(header, records) { "H|#{header[:cnes]}|#{header[:competence]}\n" + records.map { |r| "R|#{r['record_id']}\n" }.join })
  end

  it "o registro de layouts entra vazio e congelado: nenhuma versão disponível" do
    expect(described_class::LAYOUTS).to eq({})
    expect(described_class::LAYOUTS).to be_frozen
    expect(described_class.available?(nil)).to be(false)
    expect(described_class.available?("1.5")).to be(false)
    expect(Psychosocial::Raas.config["layout_version"]).to be_nil
  end

  it "com um layout registrado, gera o texto pelo writer da versão" do
    stub_const("Psychosocial::RaasFile::LAYOUTS", { "test-1" => layout }.freeze)

    expect(described_class.available?("test-1")).to be(true)
    expect(described_class.available?(:"test-1")).to be(false)
    text = described_class.build(version: "test-1", header: { cnes: "1234567", competence: "202611", month: "2026-11", unit_name: "CAPS" },
                                 records: [ { "record_id" => "r1" }, { "record_id" => "r2" } ])
    expect(text).to eq("H|1234567|202611\nR|r1\nR|r2\n")
  end

  it "versão fora do registro → KeyError que cita só a versão" do
    expect { described_class.build(version: "9.9", header: {}, records: [ { "patient" => { "name" => "Fulano de Tal" } } ]) }
      .to raise_error(KeyError) { |error| expect(error.message).not_to include("Fulano") }
  end
end
