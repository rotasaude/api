require "rails_helper"

# Spec §2 decisão 9; plano, Desvio 13. Contas conferidas ao escrever o plano.
RSpec.describe CareLines::Preview do
  include ActiveSupport::Testing::TimeHelpers

  before do
    care_city!
    care_lines_loaded!
  end

  let(:today) { Time.zone.today }
  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let!(:team) { care_team!(unit, doctor) }

  it "C4: população elegível (inscrita ou não), pesos redistribuídos sem a visita do ACS, declaração e resolvido fora" do
    enrolled = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    care_enrollment!(patient: enrolled, line: adopted_line!("diabetes_c4"), team: team, by: doctor)
    loose = care_patient!(age: 62, sex: "female", problems: [ %w[cid10 E119] ], unit: unit, doctor: doctor)
    exam_order!(patient: loose, unit: unit, requester: doctor, sigtap_code: "0202010503", status: :awaiting_authorization)
    cured = care_patient!(age: 50, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    resolve_problem!(cured, "T90", by: doctor)
    declared = care_citizen!(age: 40, sex: "female", neighborhood: care_neighborhood!(unit))
    declare!(declared, "diabetes")

    result = described_class.call(team: team, indicator: "C4", today: today)
    expect(result).to include(indicator: "C4", denominator: 2, max_score: 100, estimate: true, template_version: 1,
                              excluded: %w[acs_visit])
    expect(result[:practices].map { |p| p.values_at(:key, :tracked, :weight, :achieved, :denominator) }).to eq([
      [ "c4_a", true, "25.0", 2, 2 ], [ "c4_b", true, "18.8", 2, 2 ], [ "c4_c", true, "18.8", 2, 2 ],
      [ "c4_d", false, "0.0", 0, 2 ], [ "c4_e", true, "18.8", 1, 2 ], [ "c4_f", true, "18.8", 0, 2 ]
    ])
    # (62,5 + 81,25) / 2 = 71,875
    expect(result).to include(score: "71.9", concept: "good")
  end

  it "C7: denominador por prática (faixa); vacina HPV fora" do
    neighborhood = care_neighborhood!(unit)
    care_citizen!(age: 30, sex: "female", neighborhood: neighborhood)
    care_citizen!(age: 12, sex: "female", neighborhood: neighborhood)
    care_patient!(age: 55, sex: "female", problems: [ %w[ciap2 W14] ], unit: unit, doctor: doctor)
    result = described_class.call(team: team, indicator: "C7", today: today)
    expect(result[:denominator]).to eq(3)
    expect(result[:excluded]).to eq(%w[vaccine])
    expect(result[:practices].map { |p| p.values_at(:key, :weight, :achieved, :denominator) }).to eq([
      [ "c7_a", "28.6", 0, 2 ], [ "c7_b", "0.0", 0, 1 ], [ "c7_c", "42.9", 1, 2 ], [ "c7_d", "28.6", 0, 1 ]
    ])
    # 42,857 × 1/2 = 21,43
    expect(result).to include(score: "21.4", concept: "regular")
  end

  it "equipe sem ninguém elegível: denominador 0, sem nota" do
    expect(described_class.call(team: team, indicator: "C6", today: today)).to include(denominator: 0, score: nil, concept: nil)
  end

  it "devolve a forma do contrato: equipe, versão, práticas com rótulo e pontos, nota como string" do
    care_patient!(age: 70, sex: "female", problems: [ %w[ciap2 K86] ], unit: unit, doctor: doctor)
    result = described_class.call(team: team, indicator: "C6", today: today)
    expect(result.keys).to eq(%i[indicator team template_version denominator score max_score concept practices excluded estimate])
    expect(result[:team]).to eq(id: team.id, ine: team.ine, name: team.name)
    expect(result[:practices].first.keys).to eq(%i[key label tracked points weight achieved denominator])
    expect(result[:score]).to match(/\A\d+\.\d\z/)
    expect(result[:concept]).to be_in(%w[optimal good sufficient regular])
  end

  it "não traz dado pessoal: nem na resposta, nem no inspect" do
    patient = care_patient!(age: 70, sex: "female", problems: [ %w[ciap2 K86] ], unit: unit, doctor: doctor)
    json = described_class.call(team: team, indicator: "C6", today: today).to_json
    expect(json).not_to include(patient.id.to_s)
    expect(json).not_to match(/display_name|patient_id|citizen_id|birth/)
  end

  it "usa a versão mais recente do template, adotada ou não" do
    template = CareLineTemplate.current("elderly_c6")
    saved = CareLines::Templates::Save.call(template.attributes.slice(*%w[key indicator declared_condition eligibility])
                                                .merge("name" => "Idoso (2027)", "practices" => template.practices))
    expect(saved.failure?).to be(false)
    expect(described_class.call(team: team, indicator: "C6", today: today)).to include(template_version: template.version + 1)
  end

  it "sem template carregado devolve nil (o controller responde 503)" do
    allow(CareLineTemplate).to receive(:current).with("elderly_c6").and_return(nil)
    expect(described_class.call(team: team, indicator: "C6", today: today)).to be_nil
  end

  it "nota e conceito saem do mesmo valor arredondado (tabela de bordas)" do
    table = { Rational(75) => %w[75.0 good], Rational(7504, 100) => %w[75.0 good], Rational(7505, 100) => %w[75.1 optimal],
              Rational(2504, 100) => %w[25.0 regular], Rational(2505, 100) => %w[25.1 sufficient], Rational(50) => %w[50.0 sufficient],
              Rational(5004, 100) => %w[50.0 sufficient], Rational(5005, 100) => %w[50.1 good], Rational(100) => %w[100.0 optimal],
              Rational(0) => %w[0.0 regular] }
    table.each { |score, expected| expect(described_class.grade(score)).to eq(expected), "#{score.to_f}: esperado #{expected}" }
  end

  it "C6, borda real sem stub: um paciente cumpre as duas práticas rastreadas, um cidadão nenhuma → 50.0, sufficient" do
    care_patient!(age: 70, sex: "female", problems: [ %w[ciap2 K86] ], unit: unit, doctor: doctor)
    care_citizen!(age: 70, sex: "male", neighborhood: care_neighborhood!(unit))
    result = described_class.call(team: team, indicator: "C6", today: today)
    expect(result).to include(denominator: 2, score: "50.0", concept: "sufficient")
    expect(result[:practices].select { |p| p[:tracked] }.map { |p| p.values_at(:key, :weight, :achieved, :denominator) }).to eq([
      [ "c6_a", "50.0", 1, 2 ], [ "c6_b", "50.0", 1, 2 ]
    ])
  end

  it "gestante NÃO inscrita, sem DUM, sem aborto: entra no denominador com zero nas práticas rastreadas (Desvio 13)" do
    care_patient!(age: 27, sex: "female", problems: [ %w[ciap2 W78] ], unit: unit, doctor: doctor)
    result = described_class.call(team: team, indicator: "C3", today: today)
    expect(result).to include(denominator: 1, score: "0.0", concept: "regular")
    tracked = result[:practices].select { |p| p[:tracked] }
    expect(tracked).not_to be_empty
    expect(tracked.map { |p| p[:achieved] }).to all(eq(0))
  end

  it "gestante INSCRITA entra pela DUM: aborto registrado antes da DUM não a exclui; sem inscrição, exclui" do
    mom = travel_to(100.days.ago) { care_patient!(age: 28, sex: "female", problems: [ %w[ciap2 W78], %w[ciap2 W82] ], unit: unit, doctor: doctor) }
    travel_to(100.days.ago) { care_patient!(age: 29, sex: "female", problems: [ %w[ciap2 W78], %w[ciap2 W82] ], unit: unit, doctor: doctor) }
    expect(described_class.call(team: team, indicator: "C3", today: today)).to include(denominator: 0)
    care_enrollment!(patient: mom, line: adopted_line!("pregnancy_c3"), team: team, by: doctor, anchor_date: today - 60)
    expect(described_class.call(team: team, indicator: "C3", today: today)).to include(denominator: 1)
  end
end
