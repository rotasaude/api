require "rails_helper"

# Módulo 32a (Valor fixado 7): config/urgency/sigtap.yml, sob revisão até a
# conferência com o SIGTAP oficial (gate de go-live).
RSpec.describe Urgency::Config do
  let(:config) { described_class.sigtap }

  it "carrega o YAML congelado, com as chaves exatas e sob revisão" do
    expect(YAML.safe_load_file(described_class::PATH).keys).to eq(%w[version review source classification_code care_code])
    expect(config).to be_frozen
    expect(config["review"]).to be(true)
  end

  it "códigos SIGTAP de 10 dígitos" do
    expect(config["classification_code"]).to match(/\A\d{10}\z/).and eq("0301060118")
    expect(config["care_code"]).to match(/\A\d{10}\z/).and eq("0301060096")
  end

  it "chave desconhecida falha" do
    path = Rails.root.join("tmp/urgency_sigtap_bad.yml")
    File.write(path, YAML.dump(YAML.safe_load_file(described_class::PATH).merge("extra" => 1)))
    expect { described_class.load(path) }.to raise_error(ArgumentError, /desconhecida/)
  ensure
    FileUtils.rm_f(path)
  end

  it "catálogo: cores, esperas e só enfermagem classifica (Q2)" do
    expect(Urgency::Catalog::COLORS).to eq(%w[red orange yellow green blue])
    expect(Urgency::Catalog::DEFAULT_MAX_WAIT.values).to eq([ 0, 10, 60, 120, 240 ])
    expect(Urgency::Catalog::CLASSIFIER_CBO_PREFIXES).to eq(%w[2235])
  end

  it "filtra os parâmetros clínicos da urgência no log" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    %w[complaint criterion vital_signs description return_guidance].each do |k|
      expect(filter.filter(k => "x")[k]).to eq("[FILTERED]")
    end
  end

  it "os portões ficam fechados sem cidade" do
    expect(Urgency::Gate.usable?(nil)).to be(false)
    expect(WaitingRoom::Gate.usable?(nil)).to be(false)
  end
end
