# spec/services/medications/obm_import_spec.rb
require "rails_helper"

# Módulo 27b, Q12: a carga OBM é por arquivo, com mapa de colunas. O VMP do
# catálogo sai da coluna CATMAT; o que não casa vai para a lista de revisão.
RSpec.describe Medications::ObmImport, type: :model do
  let(:sample) { Rails.root.join("spec/fixtures/obm/sample.csv").read }
  let(:now) { Time.zone.parse("2026-11-25 10:00") }

  before { import_test_catalog! }

  def import!(csv = sample, by: "system") = described_class.call(csv: csv, by: by, now: now)

  # Cabeçalho + linhas do arquivo de exemplo, para variar uma coisa por vez.
  def lines = sample.lines.map(&:chomp)
  def csv_of(*rows, header: lines.first) = ([ header ] + rows).join("\n") + "\n"

  it "a amostra cria 3 apresentações e liga o VMP a 2 itens pelo CATMAT; 1 fica em unmatched" do
    result = import!

    expect(result).to be_ok
    expect(result.payload).to eq(added: 3, changed: 0, deactivated: 0, vmp_linked: 2, unmatched: 1)
    expect(ObmPresentation.count).to eq(3)
    expect(ObmPresentation.find_by!(ampp_code: "@brasil20038375080"))
      .to have_attributes(vmp_code: "@brasil10000001", catmat_code: 268_856, anvisa_registration: "1234567890123",
                          manufacturer_cnpj: "12345678000195", active: true, imported_at: now)
    expect(ObmPresentation.find_by!(ampp_code: "@brasil20038375081"))
      .to have_attributes(anvisa_registration: "1023500010012", manufacturer_cnpj: nil)
    expect(catalog_item(268_856).vmp_code).to eq("@brasil10000001")
    expect(catalog_item(267_778).vmp_code).to eq("@brasil10000002")
    expect(ObmPresentation.unmatched.pluck(:ampp_code)).to eq([ "@brasil20038375082" ])
  end

  it "reimportar o mesmo arquivo não muda nada; descrição nova conta em changed" do
    import!
    expect(import!.payload).to eq(added: 0, changed: 0, deactivated: 0, vmp_linked: 2, unmatched: 1)

    changed = sample.sub("LOSARTANA POTASSICA 50 MG", "LOSARTANA POTASSICA 100 MG")
    expect(import!(changed).payload).to include(added: 0, changed: 1)
  end

  it "reimportar sem uma AMPP a desativa e não apaga" do
    import!
    result = import!(csv_of(*lines.drop(1).first(2)))

    expect(result.payload).to include(added: 0, deactivated: 1)
    expect(ObmPresentation.find_by!(ampp_code: "@brasil20038375082").active).to be(false)
    expect(ObmPresentation.count).to eq(3)

    # Voltou no arquivo seguinte: reativa e conta como mudança.
    expect(import!.payload).to include(added: 0, changed: 1, deactivated: 0)
    expect(ObmPresentation.find_by!(ampp_code: "@brasil20038375082").active).to be(true)
  end

  it "fonte sem o par CATMAT não apaga o vmp_code gravado" do
    import!
    import!(csv_of(lines[3], "@brasil20038375099;@brasil10000009;;;;SEM CATMAT 5 MG COM X 10"))

    expect(catalog_item(268_856).vmp_code).to eq("@brasil10000001")
    expect(catalog_item(267_778).vmp_code).to eq("@brasil10000002")
  end

  it "o banco recusa apagar apresentação" do
    import!
    expect { PlatformRecord.transaction(requires_new: true) { ObmPresentation.first.destroy } }
      .to raise_error(ActiveRecord::StatementInvalid, /never deleted/)
  end

  it "item removido do catálogo não recebe VMP e a apresentação vai à revisão" do
    catalog_item(268_856).update_columns(status: "removed")
    expect(import!.payload).to include(vmp_linked: 1, unmatched: 2)
    expect(catalog_item(268_856).vmp_code).to be_nil
  end

  it "aceita BOM, CRLF, vírgula como separador e cabeçalho com outro nome do mapa" do
    csv = "﻿CODIGO_AMPP,CODIGO_VMP,Código CATMAT,Descrição\r\n@brasil20038375080,@brasil10000001,268856,\"LOSARTANA, 50 MG\"\r\n"
    expect(import!(csv).payload).to include(added: 1, vmp_linked: 1, unmatched: 0)
    expect(ObmPresentation.last.description).to eq("LOSARTANA, 50 MG")
  end

  it "cabeçalho faltando → invalid_file" do
    result = import!(sample.sub("CATMAT", "OUTRA"))

    expect(result.reason).to eq(:invalid_file)
    expect(result.details).to eq(path: "file")
    expect(result.message).to include("catmat")
    expect(ObmPresentation.count).to eq(0)
  end

  it "arquivo ruim → invalid_file e nada gravado; a mensagem não repete o conteúdo" do
    [ csv_of("@brasil1;;268856;;;SEGREDO-NA-LINHA"),
      csv_of(lines[1], lines[1]),
      csv_of("@brasil1;@brasil2;abc;;;DESCRICAO"),
      csv_of("@brasil1;@brasil2;1;;123;DESCRICAO"),
      csv_of("@brasil1;@brasil2;1;;;" + ("x" * 501)),
      csv_of("ampp com espaço;@brasil2;1;;;DESCRICAO"),
      "AMPP;VMP;CATMAT;DESCRICAO\n@a;@b;1;COMPRIMIDO SÃO".encode("ISO-8859-1"),
      "",
      "AMPP;VMP;CATMAT;DESCRICAO\n@a;\"aberta" ].each do |csv|
      result = import!(csv)
      expect(result.reason).to eq(:invalid_file), csv.first(60)
      expect(result.message.to_s).not_to include("SEGREDO")
    end
    expect(ObmPresentation.count).to eq(0)
    expect(PlatformEvent.where(name: "obm_catalog.imported")).to be_empty
  end

  it "arquivo acima do limite → file_too_large" do
    stub_const("Medications::ObmImport::MAX_BYTES", 100)
    result = import!

    expect(result.reason).to eq(:file_too_large)
    expect(result.details).to eq(path: "file")
  end

  it "metade dos ativos some → suspicious_drop, nada muda" do
    import!
    result = import!(csv_of(lines[1]))

    expect(result.reason).to eq(:suspicious_drop)
    expect(result.details).to eq(path: "file")
    expect(ObmPresentation.where(active: true).count).to eq(3)
  end

  it "Platform.audit(\"obm_catalog.imported\") só com contagens" do
    import!
    event = PlatformEvent.where(name: "obm_catalog.imported").last
    expect(event.payload).to eq("actor" => "system", "added" => 3, "changed" => 0, "deactivated" => 0, "unmatched" => 1)

    import!(by: "maintenance:abc")
    expect(PlatformEvent.where(name: "obm_catalog.imported").last.payload["actor"]).to eq("maintainer")
    expect(PlatformEvent.where(name: "obm_catalog.imported").last.payload.to_s).not_to include("brasil", "LOSARTANA")
  end
end
