require "rails_helper"
require Rails.root.join("lib/sigtap_sample").to_s

# Módulo 31 (contrato §12): a SIGTAP da plataforma passa a guardar a quantidade
# máxima, os dias de permanência e os atributos complementares de cada
# procedimento (rl_procedimento_detalhe / CO_DETALHE). 0, 9999 e vazio = sem limite.
RSpec.describe Terminology::SigtapReader do
  def import(dir, competence = "202611")
    Terminology::Import.call(kind: "sigtap", version: competence, path: dir, by: "spec")
  end

  it "grava quantidade máxima, permanência e atributos; 9999 e 0 viram nulo" do
    result = Dir.mktmpdir { |dir| import(SigtapSample.write_to(dir, competence: "202611")) }
    release = result.payload[:release]
    night = SigtapProcedure.find_by!(release_id: release.id, code: "0301080020")
    expect([ night.max_quantity, night.max_stay_days ]).to eq([ 1, 14 ])
    consult = SigtapProcedure.find_by!(release_id: release.id, code: "0301010064")
    expect([ consult.max_quantity, consult.max_stay_days ]).to eq([ nil, nil ])
    expect(SigtapProcedureAttribute.where(release_id: release.id, procedure_code: "0301080291").pluck(:attribute_code)).to eq(%w[036])
    expect(result.payload[:counts]).to include(sigtap_procedure_attributes: 1)
  end

  it "Review Focus 4: pacote sem o arquivo de atributos importa com zero atributos" do
    result = Dir.mktmpdir do |dir|
      SigtapSample.write_to(dir, competence: "202611")
      FileUtils.rm(Dir.glob(File.join(dir, "rl_procedimento_detalhe*")))
      import(dir)
    end
    expect(result).to be_ok
    expect(result.payload[:counts]).to include(sigtap_procedure_attributes: 0)
    expect(SigtapProcedure.find_by!(release_id: result.payload[:release].id, code: "0301080208").max_quantity).to eq(31)
  end

  it "atributo com código fora de 3 dígitos recusa a release inteira" do
    result = Dir.mktmpdir do |dir|
      SigtapSample.write_to(dir, competence: "202611")
      path = File.join(dir, "rl_procedimento_detalhe.txt")
      File.binwrite(path, File.binread(path).sub("036", "3X6"))
      import(dir)
    end
    expect(result.reason).to eq(:invalid_file)
    expect(TerminologyRelease.where(kind: "sigtap", version: "202611", status: "active")).to be_empty
  end

  it "quantidade máxima não numérica recusa a release inteira" do
    result = Dir.mktmpdir do |dir|
      SigtapSample.write_to(dir, competence: "202611")
      path = File.join(dir, "tb_procedimento.txt")
      File.binwrite(path, File.binread(path).sub("00010014", "00X10014"))
      import(dir)
    end
    expect(result.reason).to eq(:invalid_file)
    expect(TerminologyRelease.where(kind: "sigtap", version: "202611", status: "active")).to be_empty
  end

  it "linha de atributo de release ativa é imutável" do
    release = Dir.mktmpdir { |dir| import(SigtapSample.write_to(dir, competence: "202611")) }.payload[:release]
    row = SigtapProcedureAttribute.find_by!(release_id: release.id)
    expect { row.update_column(:attribute_code, "009") }.to raise_error(ActiveRecord::StatementInvalid, /immutable/)
  end

  it "o banco recusa quantidade máxima e permanência não positivas" do
    release = TerminologyRelease.create!(kind: "sigtap", version: "202501", source_sha256: "c" * 64, imported_by: "spec",
                                         imported_at: Time.current, status: "importing")
    expect { SigtapProcedure.create!(release: release, code: "0301080208", name: "X", max_quantity: 0) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_sigtap_procedures_limits/)
    expect { SigtapProcedure.create!(release: release, code: "0301080216", name: "X", max_stay_days: -1) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_sigtap_procedures_limits/)
  end
end
