require "rails_helper"

# ADR 0031 (spec §7; contratos §5): CIAP-2 e CID-10 da release ativa da
# plataforma; SIGTAP da competência ativa, só exames (grupo 02).
RSpec.describe ClinicalTerms do
  before { ciap2_release!; cid10_release!; sigtap_release! }

  it "acha por código com ou sem ponto, com rótulo e release; desconhecido é nil" do
    code = described_class.find("cid10", "e11.9")
    expect([ code.code, code.label, code.release_id ])
      .to eq([ "E119", ClinicalRecordHelpers::CID10["E119"].first, TerminologyRelease.active.find_by!(kind: "cid10").id ])
    expect(described_class.find("ciap2", "t90").code).to eq("T90")
    expect(described_class.find("cid10", "Z999")).to be_nil
    expect(described_class.find("loinc", "1")).to be_nil
    expect(described_class.cid10_sex("C61", code.release_id)).to eq("M")
  end

  it "busca CID-10 por código ou nome, sem acento e sem caixa, até o limite" do
    expect(described_class.search("cid10", "hipertensao").map(&:code)).to eq([ "I10" ])
    expect(described_class.search("cid10", "e11").map(&:code)).to eq([ "E119" ])
    expect(described_class.search("cid10", "").map(&:code)).to eq([])
    expect(described_class.search("cid10", "a", limit: 2).size).to eq(2)
  end

  it "SIGTAP: só grupo 02, com a competência; busca por código ou nome" do
    exam = ClinicalTerms::SigtapExams.find("0202010503", on: Time.zone.today)
    expect([ exam.code, exam.label, exam.competence ])
      .to eq([ "0202010503", "DOSAGEM DE HEMOGLOBINA GLICOSILADA", Time.zone.today.strftime("%Y%m") ])
    expect(ClinicalTerms::SigtapExams.find("0301010064", on: Time.zone.today)).to be_nil
    expect(ClinicalTerms::SigtapExams.find("02.02.01.050-3", on: Time.zone.today)&.code).to eq("0202010503")
    expect(ClinicalTerms::SigtapExams.search("glicosilada", on: Time.zone.today).map(&:code)).to eq([ "0202010503" ])
    expect(ClinicalTerms::SigtapExams.search("consulta", on: Time.zone.today)).to eq([])
  end
end
