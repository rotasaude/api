require "rails_helper"

RSpec.describe Medications::AnvisaImport do
  it "importa as duas listas, ativa a release e audita só contagens" do
    result = described_class.call(by: "rspec", dir: anvisa_fixture_dir)
    expect(result).to be_ok
    release = AnvisaListRelease.current
    expect(release).to have_attributes(antimicrobials_count: 7, controlled_count: 6, imported_by: "rspec")
    expect(release.sources.dig("antimicrobials", "label")).to include("Fixture")
    expect(AnvisaListSubstance.where(release_id: release.id, kind: "controlled").pluck(:substance_key, :controlled_list).to_h)
      .to include("CODEINA" => "A2", "DIAZEPAM" => "B1")
    event = PlatformEvent.where(name: "anvisa_lists.imported").last
    expect(event.payload).to eq("release_id" => release.id, "antimicrobials" => 7, "controlled" => 6)
  end

  it "arquivo que não bate com o SOURCES.yml falha sem ativar nada" do
    Dir.mktmpdir do |dir|
      FileUtils.cp_r("#{anvisa_fixture_dir}/.", dir)
      File.write(File.join(dir, "antimicrobials.csv"), "substance\nAMOXICILINA\n")
      result = described_class.call(by: "rspec", dir: dir)
      expect([ result.reason, AnvisaListRelease.current ]).to eq([ :invalid_file, nil ])
      expect(result.message).to include("antimicrobials")
    end
  end

  it "release importing parada há mais de 1 h vira failed e libera nova importação" do
    AnvisaListRelease.create!(imported_by: "old", imported_at: 2.hours.ago, status: "importing", source_sha256: "x", sources: {})
    expect(described_class.call(by: "rspec", dir: anvisa_fixture_dir)).to be_ok
    expect(AnvisaListRelease.where(status: "failed").count).to eq(1)
  end

  it "importação em curso (< 1 h) → import_in_progress" do
    AnvisaListRelease.create!(imported_by: "other", imported_at: 1.minute.ago, status: "importing", source_sha256: "x", sources: {})
    expect(described_class.call(by: "rspec", dir: anvisa_fixture_dir).reason).to eq(:import_in_progress)
  end
end
