require "rails_helper"

# Módulo 28 (ADR 0046; contrato §16 O3): o odontograma é a dobra dos
# dental_chart_events do paciente em (recorded_at, id). Eventos gravados
# direto no banco, numa consulta odontológica em rascunho.
RSpec.describe DentalCare::Chart do
  before { dental_city! }

  let(:unit) { create_unit }
  let(:dentist) { dentist!(unit) }
  let(:citizen) { verified_citizen!(1) }
  let(:draft) { dental_draft_row!(unit: unit, by: dentist, citizen: citizen) }
  let(:patient) { draft.patient }
  let(:t0) { Time.zone.parse("2026-10-01 09:00") }

  def event!(tooth:, at:, situation: nil, part: "crown", face: nil, procedure: nil, consultation: draft, addendum: nil)
    DentalChartEvent.create!(patient: consultation.patient, consultation: consultation, addendum: addendum, author_user: dentist,
                             cbo_code: "223208", tooth: tooth, part: part, face: face, situation: situation,
                             procedure_code: procedure, recorded_at: at)
  end

  def tooth(chart, number) = chart.fetch(:teeth).find { |t| t[:tooth] == number }

  it "cárie na face M do 11 e depois restauração 0307010031 na M → face restored" do
    event!(tooth: 11, face: "M", situation: "caries", at: t0)
    event!(tooth: 11, face: "M", situation: "restored", procedure: "0307010031", at: t0 + 1.hour)
    event!(tooth: 11, face: "D", situation: "caries", at: t0 + 2.hours)
    eleven = tooth(described_class.call(patient), 11)
    expect(eleven).to include(tooth: 11, situation: nil, root: nil, last_event_at: t0 + 2.hours, notes_count: 3)
    expect(eleven[:faces]).to eq("M" => "restored", "D" => "caries", "O" => nil, "V" => nil, "L" => nil)
  end

  it "exodontia do 36 → coroa extracted e faces vazias; a raiz segue a dela" do
    event!(tooth: 36, face: "O", situation: "caries", at: t0)
    event!(tooth: 36, part: "root", situation: "endodontics", at: t0 + 1.minute)
    event!(tooth: 36, situation: "extracted", procedure: "0414020138", at: t0 + 1.hour)
    thirty_six = tooth(described_class.call(patient), 36)
    expect(thirty_six).to include(situation: "extracted", root: "endodontics")
    expect(thirty_six[:faces].values).to all(be_nil)
  end

  it "evento só com procedimento não muda a situação, mas conta e data o dente" do
    event!(tooth: 21, situation: "sound", at: t0)
    event!(tooth: 21, procedure: "0204010225", at: t0 + 1.hour)
    expect(tooth(described_class.call(patient), 21)).to include(situation: "sound", notes_count: 2, last_event_at: t0 + 1.hour)
  end

  it "achado de adendo posterior muda a coroa (o adendo vence pela ordem)" do
    doctor = doctor!(unit)
    older = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    current = dental_draft_row!(unit: unit, by: dentist, citizen: citizen.reload)
    expect(current.patient_id).to eq(older.patient_id)
    event!(tooth: 26, situation: "caries", at: t0, consultation: current)
    addendum = ConsultationAddendum.create!(consultation: older, author_user: doctor, reason: "Correção do achado registrado",
                                            text: "Achado corrigido")
    event!(tooth: 26, situation: "restored", at: t0 + 1.day, consultation: older, addendum: addendum)
    expect(tooth(described_class.call(current.patient), 26)[:situation]).to eq("restored")
    expect(tooth(described_class.call(current.patient, as_of: t0 + 1.hour), 26)[:situation]).to eq("caries")
  end

  it "mesmo recorded_at: desempata pelo id" do
    a = event!(tooth: 12, situation: "caries", at: t0)
    b = event!(tooth: 12, situation: "restored", at: t0)
    last = [ a, b ].max_by(&:id)
    expect(tooth(described_class.call(patient), 12)[:situation]).to eq(last.situation)
  end

  it "complete_denture na arcada superior → todos os dentes superiores, até um evento posterior" do
    upper = DentalCare::Location.teeth(DentalCare::Location.parse(kind: "arch", arch: "upper").payload[:location])
    upper.each { |number| event!(tooth: number, situation: "complete_denture", at: t0) }
    event!(tooth: 11, situation: "sound", at: t0 + 1.hour)
    chart = described_class.call(patient)
    expect((upper - [ 11 ]).map { |n| tooth(chart, n)[:situation] }.uniq).to eq([ "complete_denture" ])
    expect(tooth(chart, 11)[:situation]).to eq("sound")
    expect(tooth(chart, 31)[:situation]).to be_nil
  end

  it "todos os 52 dentes, na ordem do catálogo" do
    chart = described_class.call(patient)
    expect(chart[:teeth].map { |t| t[:tooth] }).to eq(DentalCare::Catalog::PERMANENT_TEETH + DentalCare::Catalog::DECIDUOUS_TEETH)
    expect(chart[:teeth].first).to eq(tooth: 11, situation: nil, root: nil, faces: { "M" => nil, "D" => nil, "O" => nil, "V" => nil, "L" => nil },
                                      last_event_at: nil, notes_count: 0)
  end

  describe "dentição" do
    it "criança de 8 anos sem evento → mixed; 4 anos → deciduous; adulto → permanent" do
      child = dental_draft_row!(unit: unit, by: dentist, citizen: verified_citizen!(2, age: 8))
      expect(described_class.call(child.patient)[:dentition]).to eq("mixed")
      toddler = dental_draft_row!(unit: unit, by: dentist, citizen: verified_citizen!(3, age: 4))
      expect(described_class.call(toddler.patient)[:dentition]).to eq("deciduous")
      expect(described_class.call(patient)[:dentition]).to eq("permanent")
    end

    it "pelos dentes presentes: só decíduo → deciduous; os dois → mixed; decíduo extraído não conta" do
      child = dental_draft_row!(unit: unit, by: dentist, citizen: verified_citizen!(2, age: 8))
      event!(tooth: 54, situation: "sound", at: t0, consultation: child)
      expect(described_class.call(child.patient)[:dentition]).to eq("deciduous")
      event!(tooth: 16, situation: "sound", at: t0, consultation: child)
      expect(described_class.call(child.patient)[:dentition]).to eq("mixed")
      event!(tooth: 54, situation: "extracted", at: t0 + 1.hour, consultation: child)
      expect(described_class.call(child.patient)[:dentition]).to eq("permanent")
    end
  end
end
