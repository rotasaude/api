require "rails_helper"
require Rails.root.join("lib/sigtap_sample").to_s

# ADR 0028 (spec 2026-10-05 §4): compatibilidade de procedimento com CBO,
# idade, sexo e CID na competência; competência sem release cai na última
# ativa anterior. Alerta no dia 5 sem a SIGTAP da competência corrente.
RSpec.describe Terminology::Sigtap do
  let(:tmp) { Pathname(Dir.mktmpdir) }
  after { FileUtils.remove_entry(tmp) }

  def import(version)
    Terminology::Import.call(kind: "sigtap", version: version, path: SigtapSample.write_to(tmp.join(version), competence: version))
  end

  before { import("202610") }

  def check(**overrides)
    described_class.compatible?("0201020033", **{ competence: "202610", cbo: "223505", age_months: 360, sex: "female",
                                                  cid: "Z01.4" }.merge(overrides))
  end

  it "tudo compatível" do
    expect(check).to eq(ok: true, reasons: [], release_version: "202610")
  end

  it "cada regra quebrada dá o seu motivo" do
    expect(check(sex: "male")[:reasons]).to eq(%w[sex_incompatible])
    expect(check(age_months: 100)[:reasons]).to eq(%w[age_below_minimum])
    expect(check(age_months: 1600)[:reasons]).to eq(%w[age_above_maximum])
    expect(check(cbo: "322205")[:reasons]).to eq(%w[cbo_incompatible])
    expect(check(cid: "I10")[:reasons]).to eq(%w[cid_incompatible])
    expect(check(sex: "M", cbo: "322205")).to include(ok: false, reasons: %w[sex_incompatible cbo_incompatible])
  end

  it "sem limite de idade, sem sexo e sem CID exigido não recusam; argumento nil não é conferido" do
    expect(described_class.compatible?("0301010064", competence: "202610", cbo: "225125", age_months: 1700,
                                                     sex: "male", cid: "I10")[:ok]).to be(true)
    expect(check(cbo: nil, age_months: nil, sex: nil, cid: nil)[:ok]).to be(true)
  end

  it "competência sem release cai na anterior; antes da primeira não há release; código desconhecido" do
    expect(check(competence: "202612")[:release_version]).to eq("202610")
    expect(check(competence: "202608")).to eq(ok: false, reasons: %w[no_release], release_version: nil)
    expect(described_class.compatible?("0000000000", competence: "202610")[:reasons]).to eq(%w[unknown_procedure])
    expect { check(competence: "2026-10") }.to raise_error(ArgumentError)
  end

  describe Terminology::SigtapStatus do
    it "alerta a partir do dia 5 só quando a competência corrente não foi importada" do
      expect(described_class.call(today: Date.new(2026, 10, 9)))
        .to eq(sigtap_current_competence: "202610", sigtap_imported: true, alert: false)
      expect(described_class.call(today: Date.new(2026, 11, 4))).to include(sigtap_imported: false, alert: false)
      expect(described_class.call(today: Date.new(2026, 11, 5))).to include(sigtap_current_competence: "202611", alert: true)
    end
  end
end
