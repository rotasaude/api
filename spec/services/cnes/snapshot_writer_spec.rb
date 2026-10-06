require "rails_helper"

# ADR 0028 (spec 2026-10-05 §5, §8): um retrato por município e competência
# (reimportar substitui), últimas 13 competências por município, CPF/CNS do
# profissional cifrados na plataforma.
RSpec.describe Cnes::SnapshotWriter do
  def write(competence, ibge_code: "4106902", bonds: [])
    described_class.write!(competence: competence, ibge_code: ibge_code,
                           establishments: [ { cnes: "0000001", name: "UBS JARDIM DAS FLORES", unit_type: "02" } ],
                           teams: [ { ine: "0000123456", kind: "70", cnes: "0000001", name: "ESF 1", active: true } ],
                           bonds: bonds)
  end

  let(:bond) { { cnes: "0000001", ine: "0000123456", cbo_code: "225125", cpf: "52998224725", cns: "700000000000005" } }

  it "grava o retrato e cifra CPF e CNS (uma só vez)" do
    snapshot = write("202609", bonds: [ bond ])
    expect(snapshot.establishments.pluck(:name)).to eq([ "UBS JARDIM DAS FLORES" ])
    expect(snapshot.teams.pluck(:ine, :active)).to eq([ [ "0000123456", true ] ])
    stored = CnesProfessionalBond.find(snapshot.bonds.first.id)
    expect([ stored.cpf, stored.cns ]).to eq(%w[52998224725 700000000000005])
    expect(stored.cpf_masked).to eq("***.982.247-**")
    raw = PlatformRecord.connection.select_one("SELECT cpf, cns FROM cnes_professional_bonds WHERE id = #{stored.id}")
    expect(raw.values.join).not_to include("52998224725")
    expect(raw.values.join).not_to include("700000000000005")
    # Cifrado uma única vez: o texto cru decifra direto para o valor original.
    expect(stored.cpf_before_type_cast).not_to eq("52998224725")
    expect(stored.cpf).to eq("52998224725")
  end

  it "aceita CPF e CNS nulos" do
    snapshot = write("202609", bonds: [ bond.merge(cpf: nil, cns: nil) ])
    stored = CnesProfessionalBond.find(snapshot.bonds.first.id)
    expect([ stored.cpf, stored.cns, stored.cpf_masked ]).to eq([ nil, nil, nil ])
  end

  # Review Focus 3 (metade do gravador).
  it "reimportar a mesma competência substitui; a 14ª competência apaga a mais antiga, com os filhos" do
    write("202609", bonds: [ bond ])
    write("202609", bonds: [ bond, bond.merge(cbo_code: "223505") ])
    expect(CnesSnapshot.where(ibge_code: "4106902").count).to eq(1)
    expect(CnesProfessionalBond.count).to eq(2)

    competences = (0..13).map { |i| (Date.new(2025, 9, 1) >> i).strftime("%Y%m") }
    competences.each { |c| write(c) }
    write("202609", ibge_code: "4115200")
    expect(CnesSnapshot.where(ibge_code: "4106902").order(:competence).pluck(:competence)).to eq(competences.last(13))
    expect(CnesSnapshot.where(ibge_code: "4115200").count).to eq(1)
    expect(CnesEstablishment.where.not(snapshot_id: CnesSnapshot.select(:id))).to be_empty
  end

  it "competência e IBGE fora do formato são recusados pelo banco" do
    expect { write("2026-09") }.to raise_error(ActiveRecord::StatementInvalid)
    expect { write("202609", ibge_code: "410690") }.to raise_error(ActiveRecord::StatementInvalid)
  end
end
