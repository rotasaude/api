require "rails_helper"

# Módulo 24c (ADR 0053; Q12): o recorte do mapa pelo CLI go-pmtiles, chamado
# por lista de argumentos (nunca shell). A saída do processo não vai ao log.
RSpec.describe FieldMaps::Cli, type: :model do
  let(:ok) { instance_double(Process::Status, success?: true, exitstatus: 0) }
  let(:failed) { instance_double(Process::Status, success?: false, exitstatus: 1) }
  let(:args) { { input: "/tmp/base.pmtiles", output: "/tmp/city.pmtiles", bbox: [ -49.42, -25.67, -49.16, -25.32 ], maxzoom: 15 } }

  it "monta o argv sem shell, com a caixa e o zoom máximo" do
    expect(Open3).to receive(:capture2e)
      .with(FieldMaps::Config.pmtiles_bin, "extract", "/tmp/base.pmtiles", "/tmp/city.pmtiles", "--bbox=-49.42,-25.67,-49.16,-25.32", "--maxzoom=15")
      .and_return([ "", ok ])
    expect(described_class.extract(**args)).to be_ok
    expect(FieldMaps::Config.pmtiles_bin).to eq("/usr/local/bin/pmtiles")
  end

  it "código de saída diferente de zero → extract_failed, e o log tem só o código" do
    allow(Open3).to receive(:capture2e).and_return([ "fetching https://exemplo.test/segredo?token=abc\nfailed", failed ])
    result = nil
    log = capture_log { result = described_class.extract(**args) }
    expect(result.reason).to eq(:extract_failed)
    expect(result.to_h.to_s).not_to include("segredo")
    expect(log).to include("exit=1")
    expect(log).not_to include("segredo")
  end

  it "binário ausente → extract_failed, sem estourar" do
    allow(Open3).to receive(:capture2e).and_raise(Errno::ENOENT)
    expect(described_class.extract(**args).reason).to eq(:extract_failed)
  end

  it "recorta o fixture com o binário de verdade", :pmtiles_cli do
    Dir.mktmpdir do |dir|
      output = File.join(dir, "out.pmtiles")
      result = described_class.extract(input: Rails.root.join("spec/fixtures/field_maps/sample.pmtiles").to_s, output: output,
                                       bbox: [ -49.272, -25.434, -49.268, -25.430 ], maxzoom: 15)
      expect(result).to be_ok
      expect(File.binread(output, 7)).to eq("PMTiles")
    end
  end
end
