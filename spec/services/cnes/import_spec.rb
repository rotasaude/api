# spec/services/cnes/import_spec.rb
require "rails_helper"

# ADR 0028 (spec 2026-10-05 §5, §8): a base mensal grava só os municípios das
# cidades ativas (IBGE lido do city_profile de cada uma); cidade sem IBGE ou
# fora do ar é pulada sem derrubar as outras; reimportar substitui.
RSpec.describe Cnes::Import do
  let(:path) { Rails.root.join("spec/fixtures/cnes/202609") }
  let!(:city) do
    City.find_by(slug: TEST_CITY_A.slug) ||
      City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active",
                   database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key,
                   schema_version: CitySchema.expected_version.to_s)
  end
  before { CityProfile.create!(name: "Curitiba", uf: "PR", ibge_code: "4106902") }
  after { CityCatalog.reset_cache! }

  it "grava o retrato de Curitiba: estabelecimentos, equipes (INE com zeros), vínculos ativos; nada de outro município" do
    result = described_class.call(competence: "202609", path: path)

    expect(result).to be_ok
    expect(result.payload[:imported]).to eq("4106902" => { establishments: 4, teams: 3, bonds: 5 })
    snapshot = CnesSnapshot.find_by!(ibge_code: "4106902", competence: "202609")
    expect(snapshot.teams.order(:ine).pluck(:ine, :kind, :cnes, :active))
      .to eq([ %w[0000123456 70 0000001] + [ true ], %w[0000123457 76 0000002] + [ true ], %w[0000123458 70 0000001] + [ false ] ])
    bonds = snapshot.bonds.map { |b| [ b.cnes, b.ine, b.cbo_code, b.cpf, b.cns ] }
    expect(bonds).to contain_exactly(
      [ "0000001", "0000123456", "225125", "52998224725", "700000000000005" ],
      [ "0000001", "0000123456", "223505", "11144477735", nil ],
      [ "0000001", nil, "225125", "52998224725", "700000000000005" ],
      [ "0000003", nil, "225124", "52998224725", "700000000000005" ],
      [ "0000003", nil, "322205", "12345678909", nil ]
    )
    expect(CnesEstablishment.where(cnes: "9999999")).to be_empty
    expect(PlatformEvent.where(name: "cnes.snapshot_imported").map(&:payload))
      .to eq([ { "competence" => "202609", "ibge_codes_count" => 1 } ])
  end

  # Review Focus 3.
  it "reimportar substitui; cidade sem IBGE e cidade fora do ar são puladas" do
    create(:city, slug: "sem-ibge")
    create(:city, slug: "fora-do-ar")
    # As cidades de factory apontam para o banco da cidade de teste; simula-se
    # o perfil vazio e o banco fora do ar sem discar nenhum host morto.
    allow(CityConnection).to receive(:with).and_wrap_original do |original, c, &block|
      raise PG::ConnectionBad, "connection refused" if c.slug == "fora-do-ar"

      c.slug == "sem-ibge" ? nil : original.call(c, &block)
    end
    described_class.call(competence: "202609", path: path)
    result = described_class.call(competence: "202609", path: path)

    expect(CnesSnapshot.where(ibge_code: "4106902").count).to eq(1)
    expect(result.payload[:skipped]).to include({ slug: "sem-ibge", reason: "no_ibge_code" },
                                                { slug: "fora-do-ar", reason: "city_unreachable" })
  end

  it "competência inválida, caminho ausente e nenhuma cidade com IBGE" do
    expect(described_class.call(competence: "2026-09", path: path).reason).to eq(:invalid_competence)
    expect(described_class.call(competence: "202609", path: "/nao/existe").reason).to eq(:file_not_found)
    CityProfile.current.update!(ibge_code: nil)
    expect(described_class.call(competence: "202609", path: path).reason).to eq(:no_city)
  end

  it "CNES e INE repetidos na base não derrubam a importação: um de cada, a equipe ativa vence" do
    Dir.mktmpdir do |dir|
      FileUtils.cp(Dir[path.join("*.csv")], dir)
      File.open(File.join(dir, "tbEstabelecimento202609.csv"), "a") do |f|
        f.puts '"4106902000005";"0000001";"";"UBS DUPLICADA";"02";"410690"'
      end
      File.open(File.join(dir, "tbEquipe202609.csv"), "a") do |f|
        f.puts '"410690";"0004";"4";"70";"4106902000002";"0000123458";"ESF REATIVADA";"01/01/2026";""'
        f.puts '"410690";"0005";"5";"76";"4106902000002";"0000123457";"EAP VILA BIS";"01/01/2026";""'
      end

      result = described_class.call(competence: "202609", path: dir)

      expect(result).to be_ok
      expect(result.payload[:imported]).to eq("4106902" => { establishments: 4, teams: 3, bonds: 5 })
      snapshot = CnesSnapshot.find_by!(ibge_code: "4106902", competence: "202609")
      expect(snapshot.establishments.where(cnes: "0000001").pluck(:name)).to eq([ "UBS JARDIM DAS FLORES" ])
      expect(snapshot.teams.order(:ine).pluck(:ine, :cnes, :name, :active)).to eq([
        [ "0000123456", "0000001", "ESF JARDIM 1", true ],
        [ "0000123457", "0000002", "EAP VILA", true ],
        [ "0000123458", "0000002", "ESF REATIVADA", true ]
      ])
    end
  end

  it "falha no meio: os municípios já gravados ficam, são auditados e aparecem no resultado" do
    allow(described_class).to receive(:municipalities)
      .and_return([ { "4106902" => [ "4106902", [ city.slug ] ], "3550308" => [ "3550308", [ "outra" ] ] }, [] ])
    allow(Cnes::SnapshotWriter).to receive(:write!).and_wrap_original do |original, **kwargs|
      raise ActiveRecord::StatementInvalid, "PG::UniqueViolation: Key (cpf)=(98765432100)" if kwargs[:ibge_code] == "3550308"

      original.call(**kwargs)
    end

    result = described_class.call(competence: "202609", path: path)

    expect(result.reason).to eq(:interrupted)
    expect(result.message).to eq("ActiveRecord::StatementInvalid")
    expect(result.details).to include(imported: { "4106902" => { establishments: 4, teams: 3, bonds: 5 } },
                                      failed_ibge_code: "3550308")
    expect(result.to_h.to_s).not_to include("98765432100")
    expect(CnesSnapshot.where(competence: "202609").pluck(:ibge_code)).to eq([ "4106902" ])
    expect(PlatformEvent.where(name: "cnes.snapshot_imported").map(&:payload))
      .to eq([ { "competence" => "202609", "ibge_codes_count" => 1 } ])
  end

  it "município sem linha no arquivo vira not_in_file" do
    CityProfile.current.update!(ibge_code: "4115200")
    result = described_class.call(competence: "202609", path: path)
    expect(result.payload[:imported]).to eq({})
    expect(result.payload[:skipped]).to include(slug: city.slug, reason: "not_in_file")
  end
end
