require "rails_helper"

# Módulo 31 (Valor fixado 5; contrato P31): config/psychosocial/raas.yml — as
# listas fechadas da RAAS, sob revisão até a conferência com o aplicativo RAAS
# vigente (gate), e o layout da remessa nulo até o gate.
RSpec.describe Psychosocial::Raas do
  let(:config) { described_class.config }

  it "carrega o YAML congelado, sob revisão e sem layout de remessa" do
    expect(config).to be_frozen
    expect(config["version"]).to eq(1)
    expect(config["review"]).to be(true)
    expect(config["layout_version"]).to be_nil
    expect(config["source"]).to include("RAAS")
  end

  it "códigos SIGTAP de 10 dígitos: noite, atendimento familiar e coletivos (P31)" do
    expect(config["night_sigtap_code"]).to eq("0301080020")
    expect(config["family_care_codes"]).to eq(%w[0301080224])
    expect(config["collective_codes"]).to eq(%w[0301080216 0301080283 0301080348])
    expect(config["procedure_prefixes"]).to eq(%w[030108])
    ([ config["night_sigtap_code"] ] + config["family_care_codes"] + config["collective_codes"]).each do |code|
      expect(code).to match(/\A\d{10}\z/)
    end
  end

  it "origens, destinos e substâncias com códigos de dois dígitos em texto" do
    expect(config["destinations"]["00"]).to eq("Permanência")
    expect(config["origins"].keys).to eq(%w[01 02 03 04 05 06 07 08 09 10 11])
    expect(config["destinations"].keys).to eq(%w[00 01 02 03 04 05 06 07])
    expect(config["substances"].keys).to eq(%w[01 02 03 04 05 06 99])
    expect(described_class.label(:origins, "02")).to eq("Atenção básica")
    expect(described_class.label(:origins, "12")).to be_nil
    expect([ described_class.valid?(:destinations, "01"), described_class.valid?(:destinations, "08"),
             described_class.valid?(:destinations, 1) ]).to eq([ true, false, false ])
  end

  it "chave desconhecida ou faltante recusa a carga" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "raas.yml")
      File.write(path, File.read(described_class::PATH) + "\nunknown_key: 1\n")
      expect { described_class.load(path) }.to raise_error(ArgumentError, /unknown_key/)
      File.write(path, File.read(described_class::PATH).sub(/^collective_codes:.*$/, ""))
      expect { described_class.load(path) }.to raise_error(ArgumentError, /collective_codes/)
      File.write(path, File.read(described_class::PATH).sub(/^procedure_prefixes:.*$/, "procedure_prefixes: [\"0301\", 3]"))
      expect { described_class.load(path) }.to raise_error(ArgumentError, /procedure_prefixes/)
    end
  end
end
