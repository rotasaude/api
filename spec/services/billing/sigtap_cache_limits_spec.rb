require "rails_helper"
require Rails.root.join("lib/sigtap_sample").to_s

# Módulo 31 (contrato §12): o cache da SIGTAP lê a quantidade máxima, a
# permanência e os atributos do procedimento, memorizados por chamada.
RSpec.describe Billing::SigtapCache do
  let(:release) do
    Dir.mktmpdir do |dir|
      Terminology::Import.call(kind: "sigtap", version: "202611", path: SigtapSample.write_to(dir, competence: "202611"), by: "spec")
    end.payload[:release]
  end
  let(:cache) { described_class.new }

  def sigtap_queries
    count = 0
    callback = lambda do |*, payload|
      count += 1 if payload[:sql].match?(/sigtap_procedure|terminology_releases/) && payload[:name] != "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end

  it "lê quantidade máxima, permanência e atributos da release importada" do
    expect(cache.max_quantity(release, "0301080208")).to eq(31)
    expect(cache.max_stay_days(release, "0301080020")).to eq(14)
    expect(cache.max_stay_days(release, "0301080208")).to be_nil
    expect(cache.max_quantity(release, "0301010064")).to be_nil
    expect(cache.attributes(release, "0301080291")).to eq(Set[ "036" ])
    expect(cache.attributes(release, "0301080208")).to eq(Set[])
  end

  it "código ausente da release não inventa limite" do
    expect(cache.max_quantity(release, "0000000000")).to be_nil
    expect(cache.max_stay_days(release, "0000000000")).to be_nil
    expect(cache.attributes(release, "0000000000")).to eq(Set[])
  end

  it "release antiga, gravada sem as colunas novas: sem limite e sem atributos" do
    old = TerminologyRelease.create!(kind: "sigtap", version: "202501", source_sha256: "d" * 64, imported_by: "spec",
                                     imported_at: Time.current, status: "importing")
    SigtapProcedure.create!(release: old, code: "0301080208", name: "ATENDIMENTO INDIVIDUAL")
    expect(cache.max_quantity(old, "0301080208")).to be_nil
    expect(cache.max_stay_days(old, "0301080208")).to be_nil
    expect(cache.attributes(old, "0301080208")).to eq(Set[])
  end

  it "memoriza por chamada: a segunda leitura do mesmo código não volta ao banco" do
    read = lambda do
      cache.max_quantity(release, "0301080208")
      cache.max_stay_days(release, "0301080208")
      cache.attributes(release, "0301080291")
    end
    expect(sigtap_queries(&read)).to be_positive
    expect(sigtap_queries(&read)).to eq(0)
  end
end
