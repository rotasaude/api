require "rails_helper"

# ADR 0034: a lista da Portaria 344 por item (a mais restritiva, do 19c) e a
# marca de anticonvulsivante (art. 59) chegam ao catálogo e à varredura de
# texto livre; quem chama o Flags com três chaves (19c) segue funcionando.
RSpec.describe "Lista por item e anticonvulsivante" do
  let(:matcher) do
    Medications::Substances::Matcher.new(antimicrobials: %w[AMOXICILINA],
                                         controlled: { "CARBAMAZEPINA" => "C1", "DIAZEPAM" => "B1", "TALIDOMIDA" => "C3" },
                                         anticonvulsants: %w[CARBAMAZEPINA])
  end

  it "marca o anticonvulsivante por ingrediente e no texto livre" do
    expect(matcher.flags_for([ "CARBAMAZEPINA" ])).to have_attributes(controlled: true, controlled_list: "C1", anticonvulsant: true)
    expect(matcher.flags_for([ "DIAZEPAM" ])).to have_attributes(controlled_list: "B1", anticonvulsant: false)
    expect(matcher.scan("carbamazepina 200 mg").anticonvulsant).to be(true)
    expect(matcher.flags_for([ "TALIDOMIDA" ]).controlled_list).to eq("C3")
  end

  it "Flags com três chaves (19c) segue valendo, anticonvulsant false" do
    flags = Medications::Substances::Flags.new(antimicrobial: false, controlled: false, controlled_list: nil)
    expect(flags.anticonvulsant).to be(false)
    expect(Medications::Substances::NONE.anticonvulsant).to be(false)
  end

  it "a importação grava o tipo novo, a contagem e a marca do catálogo" do
    import_test_catalog!
    release = AnvisaListRelease.current
    expect(release.anticonvulsants_count).to eq(2)
    expect(AnvisaListSubstance.where(release_id: release.id, kind: "anticonvulsant").pluck(:substance_key))
      .to contain_exactly("CARBAMAZEPINA", "ACIDO VALPROICO")
    item = controlled_item!(code: 9_900_101, ingredient: "CARBAMAZEPINA", list: nil)
    Medications::Substances.apply_to_catalog!(Medications::Substances.matcher(release))
    item.reload
    expect(item).to have_attributes(anticonvulsant: true, controlled_list: nil)
    expect(ClinicalDocuments::Json.catalog_item(item)).to include(controlled_list: nil, anticonvulsant: true)
    expect(ClinicalDocuments::Json.catalog_ref(item)).not_to have_key(:anticonvulsant)
    expect(ClinicalDocuments::Json.catalog_ref(item)).not_to have_key(:controlled_list)
  end

  it "medicamento em uso e renovação levam as marcas no catalog_item, fora do catalog_ref" do
    import_test_catalog!
    item = controlled_item!(code: 9_900_102, ingredient: "CARBAMAZEPINA", list: "C1")
    item.update!(anticonvulsant: true)
    medication = PatientMedication.new(catalog_item_id: item.id, free_text: nil, label: "x", dosage_summary: "1x", continuous: true,
                                       status: "active", origin: "manual", updated_at: Time.current)
    json = ClinicalDocuments::Json.medication(medication, catalog: { item.id => item })
    expect(json[:catalog_item]).to include(controlled_list: "C1", anticonvulsant: true)
    expect(ClinicalDocuments::Json.catalog_ref(item).keys).to eq(%i[id catmat_code label active_ingredient strength dosage_form])
  end

  it "contagem diferente do SOURCES.yml falha a importação" do
    Dir.mktmpdir do |dir|
      FileUtils.cp(Dir[anvisa_fixture_dir.join("*")], dir)
      File.write(File.join(dir, "anticonvulsants.csv"), "substance\nCARBAMAZEPINA\n")
      result = Medications::AnvisaImport.call(by: "rspec", dir: dir)
      expect(result.reason).to eq(:invalid_file)
    end
  end
end
