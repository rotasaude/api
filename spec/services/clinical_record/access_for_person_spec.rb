require "rails_helper"

# ADR 0035 (spec §5): a leitura da linha do tempo usa as regras do 19a sobre
# A PESSOA. `call` e `for_consultation` do 19a ficam iguais (regressão abaixo).
RSpec.describe ClinicalRecord::Access do
  include ActiveSupport::Testing::TimeHelpers
  before { timeline_city!(record_mode: "integrated", clinical_record: false) }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(41) }
  let(:person) { Timeline::Person.for_cpf(citizen.cpf) }

  it "em contexto pelo atendimento chamado; outro profissional, fora de contexto" do
    attendance = consulting_attendance!(unit, citizen: citizen, doctor: doctor)
    expect(described_class.for_person(user: doctor, person: person).kind).to eq(:in_context)
    expect(described_class.for_person(user: doctor, person: person, attendance: attendance).kind).to eq(:in_context)
    other = doctor!(unit, cbo: "225142")
    expect(described_class.for_person(user: other, person: person, attendance: attendance).reason).to eq(:out_of_context)
  end

  it "atendimento de outra pessoa não dá contexto" do
    attendance = consulting_attendance!(unit, citizen: verified_citizen!(42), doctor: doctor)
    expect(described_class.for_person(user: doctor, person: person, attendance: attendance).reason).to eq(:out_of_context)
  end

  it "abertura pelo par, válida 30 min; recepção sem papel" do
    now = Time.current
    opening = ClinicalRecordOpening.create!(citizen: citizen, user: doctor, reason_code: "active_search",
                                            created_at: now, expires_at: now + 30.minutes)
    grant = described_class.for_person(user: doctor, person: person)
    expect([ grant.kind, grant.opening ]).to eq([ :justified, opening ])
    travel_to(31.minutes.from_now) { expect(described_class.for_person(user: doctor, person: person).reason).to eq(:out_of_context) }
    expect(described_class.for_person(user: reception!, person: person).reason).to eq(:missing_role)
  end
end

RSpec.describe "ClinicalRecord::Access do 19a (regressão)" do
  before { clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(43) }

  it "call e for_consultation respondem como antes" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    patient = consultation.patient
    attendance = consulting_attendance!(unit, citizen: citizen.reload, doctor: doctor)
    expect(ClinicalRecord::Access.call(user: doctor, patient: patient, attendance: attendance).kind).to eq(:in_context)
    expect(ClinicalRecord::Access.call(user: doctor!(unit, cbo: "225142"), patient: patient).reason).to eq(:out_of_context)
    expect(ClinicalRecord::Access.call(user: reception!, patient: patient).reason).to eq(:missing_role)
    expect(ClinicalRecord::Access.for_consultation(user: doctor, consultation: consultation).kind).to eq(:author)
  end
end
