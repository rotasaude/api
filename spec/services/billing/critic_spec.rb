require "rails_helper"

# ADR 0039 (spec §2 decisões 2, 4 e 6; spec §9): cada crítica SIGTAP com caso
# que passa e que falha; marca e não bloqueia; UBS nunca gera BPA; CID e
# identificação do paciente só no BPA-I; a SIGTAP da competência ou a última
# ativa anterior (fallback); motivos na ordem estável do contrato.
RSpec.describe Billing::Critic do
  before { billing_sigtap! }

  let(:today) { Time.zone.today }
  let(:upa) { Billing::Establishment.new(type: "health_unit", id: SecureRandom.uuid, cnes: "1234567", name: "UPA", kind: "upa") }
  let(:lab) { Billing::Establishment.new(type: "lab_provider", id: SecureRandom.uuid, cnes: "7654321", name: "Lab", kind: "lab") }
  let(:patient) { Patient.new(cpf: "29136237191", full_name: "Maria Aparecida da Silva", birth_date: (today - 40.years).iso8601, sex: "female") }

  def check(**over)
    described_class.call(Billing::Critic::Facts.new(**{ establishment: upa, sigtap_code: "0301060029", performed_on: today, cbo_code: "225125",
                                                        professional_cns: "798312812760829", cid10: "I10", patient: patient }.merge(over)))
  end

  it "LGPD: inspect e to_s dos fatos não expõem CNS, CPF nem nome" do
    facts = Billing::Critic::Facts.new(establishment: upa, sigtap_code: "0301060029", performed_on: today, cbo_code: "225125",
                                       professional_cns: "798312812760829", cid10: "I10", patient: patient)
    [ facts.inspect, facts.to_s, "#{facts}", PP.pp(facts, +"") ].each do |text|
      expect(text).not_to include("798312812760829", "29136237191", "Maria Aparecida")
      expect(text).to include("0301060029")
    end
  end

  it "faturável: BPA-I na UPA com CBO, CNS, CID e paciente completos" do
    expect(check).to have_attributes(instrument: "bpa_i", billable: true, reasons: [], sigtap_competence: today.strftime("%Y%m"),
                                     fallback: false, label: "ATENDIMENTO DE URGENCIA C/ OBSERVACAO ATE 24 HORAS EM ATENCAO ESPECIALIZADA")
  end

  it "UBS nunca gera BPA: o mesmo procedimento na unidade de atenção primária não é faturável" do
    expect(check(establishment: upa.with(kind: "ubs"))).to have_attributes(instrument: "bpa_i", billable: false, reasons: %w[establishment_is_aps])
    expect(upa.with(kind: "hospital").aps?).to be(false)
    expect(upa.with(kind: "other").aps?).to be(false)
    expect(lab.aps?).to be(false)
  end

  it "laboratório municipal: BPA-C com o CBO do liberador, sem CNS nem CID" do
    expect(check(establishment: lab, sigtap_code: "0202010473", cbo_code: "221205", professional_cns: nil, cid10: nil))
      .to have_attributes(instrument: "bpa_c", billable: true, reasons: [])
  end

  it "estabelecimento sem CNES" do
    expect(check(establishment: upa.with(cnes: nil)).reasons).to eq(%w[missing_establishment_cnes])
  end

  it "fora da SIGTAP da competência e instrumento que não é BPA" do
    expect(check(sigtap_code: "0399999999")).to have_attributes(instrument: "not_bpa", billable: false, reasons: %w[not_in_sigtap], label: nil)
    expect(check(sigtap_code: "0604320124", cid10: nil)).to have_attributes(instrument: "not_bpa", billable: false, reasons: %w[not_bpa_instrument])
  end

  it "BPA-I e BPA-C listados: vale o BPA-I" do
    expect(check(sigtap_code: "0201020033", cbo_code: "223505", cid10: nil)).to have_attributes(instrument: "bpa_i", billable: true)
  end

  it "CBO: ausente, não permitido e procedimento sem lista de CBO" do
    expect(check(cbo_code: nil).reasons).to eq(%w[missing_professional_cbo])
    expect(check(cbo_code: "322205").reasons).to eq(%w[cbo_not_allowed])
    expect(check(sigtap_code: "0301010064", cbo_code: "322205", cid10: nil)).to have_attributes(billable: true)
  end

  it "CNS do profissional só no BPA-I" do
    expect(check(professional_cns: nil).reasons).to eq(%w[missing_professional_cns])
    expect(check(sigtap_code: "0301100012", cbo_code: "322205", professional_cns: nil, cid10: nil).billable).to be(true)
  end

  it "idade em meses: limite inclusivo nas duas pontas" do
    young = patient.dup.tap { |p| p.birth_date = (today - 25.years).iso8601 }
    younger = patient.dup.tap { |p| p.birth_date = (today - 25.years + 1.day).iso8601 }
    old = patient.dup.tap { |p| p.birth_date = (today - 65.years).iso8601 }
    older = patient.dup.tap { |p| p.birth_date = (today - 65.years - 1.month).iso8601 }
    base = { sigtap_code: "0201020033", cbo_code: "223505", cid10: nil }
    expect(check(**base, patient: young).billable).to be(true)
    expect(check(**base, patient: younger).reasons).to eq(%w[age_out_of_range])
    expect(check(**base, patient: old).billable).to be(true)
    expect(check(**base, patient: older).reasons).to eq(%w[age_out_of_range])
  end

  it "sexo do procedimento" do
    male = patient.dup.tap { |p| p.sex = "male" }
    expect(check(sigtap_code: "0201020033", cbo_code: "223505", cid10: nil, patient: male).reasons).to eq(%w[sex_not_allowed])
  end

  it "CID: exigido, não permitido, permitido e livre quando a tabela não lista CID" do
    expect(check(cid10: nil).reasons).to eq(%w[cid_required])
    expect(check(cid10: "N390").reasons).to eq(%w[cid_not_allowed])
    expect(check(cid10: "E119").billable).to be(true)
    expect(check(sigtap_code: "0301010072", cid10: "N390").billable).to be(true)
  end

  it "CID não conta no BPA-C (o arquivo não tem a coluna)" do
    expect(check(establishment: lab, sigtap_code: "0202010473", cbo_code: "221205", cid10: "N390").billable).to be(true)
  end

  it "paciente: identificação e campos obrigatórios no BPA-I; no BPA-C só o nascimento (idade)" do
    expect(check(patient: patient.dup.tap { |p| p.cpf = "" }).reasons).to eq(%w[missing_patient_id])
    expect(check(patient: patient.dup.tap { |p| p.full_name = nil }).reasons).to eq(%w[missing_required_patient_field])
    expect(check(patient: patient.dup.tap { |p| p.sex = nil }).reasons).to eq(%w[missing_required_patient_field])
    no_birth = patient.dup.tap { |p| p.birth_date = nil }
    expect(check(patient: no_birth).reasons).to eq(%w[missing_required_patient_field])
    bpa_c = { establishment: lab, sigtap_code: "0202010473", cbo_code: "221205", professional_cns: nil, cid10: nil }
    expect(check(**bpa_c, patient: patient.dup.tap { |p| p.full_name = nil }).billable).to be(true)
    expect(check(**bpa_c, patient: no_birth).reasons).to eq(%w[missing_required_patient_field])
  end

  it "D-U1: raça/cor e endereço só contam no fechamento (closing: true), só no BPA-I" do
    expect(check.billable).to be(true)
    closing = ->(person, **over) { described_class.call(Billing::Critic::Facts.new(**{ establishment: upa, sigtap_code: "0301060029", performed_on: today,
                                                                                       cbo_code: "225125", professional_cns: "798312812760829", cid10: "I10",
                                                                                       patient: person }.merge(over)), closing: true) }
    expect(closing.call(patient).reasons).to eq(%w[missing_race_color missing_address])
    complete = patient.dup.tap { |p| p.assign_attributes(race_color: "03", address_zip: "80010000", address_street: "Rua XV", address_number: "SN", address_district: "Centro") }
    expect(closing.call(complete).billable).to be(true)
    expect(closing.call(complete.dup.tap { |p| p.race_color = "99" }).reasons).to eq(%w[missing_race_color])
    expect(closing.call(complete.dup.tap { |p| p.race_color = "05" }).reasons).to eq(%w[missing_race_color])
    expect(closing.call(complete.dup.tap { |p| p.assign_attributes(race_color: "05", ethnicity: "0001") }).billable).to be(true)
    expect(closing.call(complete.dup.tap { |p| p.address_number = nil }).billable).to be(true)
    expect(closing.call(complete.dup.tap { |p| p.address_district = nil }).reasons).to eq(%w[missing_address])
    expect(closing.call(patient, establishment: lab, sigtap_code: "0202010473", cbo_code: "221205", professional_cns: nil, cid10: nil).billable).to be(true)
  end

  it "vários motivos de uma vez, na ordem estável do contrato" do
    male = patient.dup.tap { |p| p.sex = "male" }
    outcome = check(establishment: upa.with(kind: "ubs", cnes: nil), sigtap_code: "0201020033", cbo_code: "322205", professional_cns: nil,
                    cid10: nil, patient: male)
    expect(outcome.reasons).to eq(%w[establishment_is_aps missing_establishment_cnes cbo_not_allowed missing_professional_cns sex_not_allowed])
    expect(described_class::REASONS.first(3)).to eq(%w[establishment_is_aps missing_establishment_cnes not_in_sigtap])
  end

  it "sem a release da competência vale a última ativa anterior, com aviso; sem nenhuma, fora da SIGTAP" do
    expect(check(performed_on: today.next_month)).to have_attributes(billable: true, sigtap_competence: today.strftime("%Y%m"), fallback: true)
    expect(check(performed_on: Date.new(1999, 1, 1))).to have_attributes(reasons: %w[not_in_sigtap], sigtap_competence: nil, fallback: false)
  end
end
