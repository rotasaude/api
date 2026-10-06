# spec/services/terminology/sigtap_reader_spec.rb
require "rails_helper"
require Rails.root.join("lib/sigtap_sample").to_s

# ADR 0028 (spec 2026-10-05 §4): a SIGTAP chega por competência, em largura
# fixa com o layout no próprio ZIP — o leitor obedece ao layout, então campo de
# tamanho mudado não quebra a importação.
RSpec.describe Terminology::SigtapReader do
  let(:tmp) { Pathname(Dir.mktmpdir) }
  after { FileUtils.remove_entry(tmp) }

  def import(version, dir = SigtapSample.write_to(tmp.join(version), competence: version))
    Terminology::Import.call(kind: "sigtap", version: version, path: dir)
  end

  it "grava procedimentos, CBOs, CIDs e instrumentos; 9999 vira sem limite" do
    result = import("202610")

    expect(result).to be_ok
    expect(result.payload[:counts]).to eq(sigtap_procedures: 5, sigtap_procedure_cbos: 14, sigtap_procedure_cids: 1,
                                          sigtap_procedure_instruments: 6)
    release = result.payload[:release]
    coleta = SigtapProcedure.find_by!(release: release, code: "0201020033")
    expect(coleta).to have_attributes(sex: "F", age_min_months: 120, age_max_months: 1560, complexity: "1",
                                      name: "COLETA DE MATERIAL P/ EXAME CITOPATOLOGICO DE COLO UTERINO")
    expect(SigtapProcedure.find_by!(release: release, code: "0301010064").age_max_months).to be_nil
    expect(SigtapProcedureCid.find_by!(release: release, procedure_code: "0201020033")).to have_attributes(cid_code: "Z014", principal: true)
    expect(SigtapProcedureInstrument.where(release: release, procedure_code: "0201020033").pluck(:instrument_name))
      .to contain_exactly("BPA (CONSOLIDADO)", "BPA (INDIVIDUALIZADO)")
  end

  it "obedece ao layout: nome com largura diferente continua lendo certo, do ZIP" do
    layouts = SigtapSample::LAYOUTS.merge(
      "tb_procedimento" => SigtapSample::LAYOUTS["tb_procedimento"].map { |c| c.first == "NO_PROCEDIMENTO" ? [ c[0], 300, c[2] ] : c }
    )
    stub_const("SigtapSample::LAYOUTS", layouts)
    dir = SigtapSample.write_to(tmp.join("larga"), competence: "202610")
    zip = tmp.join("TabelaUnificada_202610.zip")
    Zip::File.open(zip.to_s, create: true) { |z| dir.children.each { |f| z.add(f.basename.to_s, f.to_s) } }

    expect(import("202610", zip)).to be_ok
    expect(SigtapProcedure.where(code: "0301100039").pick(:name)).to eq("AFERICAO DE PRESSAO ARTERIAL")
  end

  it "republicação da mesma competência substitui; outra competência continua ativa" do
    first = import("202609").payload[:release]
    old = import("202610").payload[:release]
    again = import("202610", SigtapSample.write_to(tmp.join("rep"), competence: "202610")).payload[:release]
    expect([ first.reload.status, old.reload.status, again.status ]).to eq(%w[active superseded active])
  end

  it "procedimento com código inválido ou instrumento sem registro: failed" do
    dir = SigtapSample.write_to(tmp.join("ruim"), competence: "202610")
    text = dir.join("tb_procedimento.txt").binread
    dir.join("tb_procedimento.txt").binwrite(text.sub("0301010064", "03010100XX"))
    result = import("202610", dir)
    expect(result.reason).to eq(:invalid_file)
    expect(TerminologyRelease.find_by!(kind: "sigtap", version: "202610").status).to eq("failed")
    expect(SigtapProcedure.count).to eq(0)
  end
end
