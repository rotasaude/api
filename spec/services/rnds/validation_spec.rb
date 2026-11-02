require "rails_helper"

RSpec.describe Rnds::Validation do
  let!(:city) { vaccination_city!.tap { cnes_city! } }
  let(:room) { vaccine_room!(create_unit("UBS Vacina", cnes: "1234567")) }
  let(:vaccinator) { room_member!(room, role: "vaccinator") }

  before { cnes_snapshot!(bonds: [ { cnes: "1234567", cbo_code: "322205", cns: vaccinator.professional.cns, cpf: nil, ine: nil } ]) }

  def validate(dose) = described_class.call(immunization: dose, entry: dose.rnds_outbox_entries.first, city: city)

  it "paciente só com CNS passa; sem CPF e sem CNS bloqueia" do
    with_cns = record!(room, vaccine_patient!(birth_date: Date.current - 70, cpf: false, cns: true), by: vaccinator)
    expect(validate(with_cns)).to eq(:ok)
    none = record!(room, vaccine_patient!(birth_date: Date.current - 70, cpf: false, cns: false), by: vaccinator)
    expect(validate(none)).to eq([ :blocked, "patient_without_cns_or_cpf" ])
  end

  it "paciente com CPF e sem CNS passa" do
    dose = record!(room, vaccine_patient!(birth_date: Date.current - 70, cpf: true, cns: false), by: vaccinator)
    expect(validate(dose)).to eq(:ok)
  end

  it "vacinador fora do retrato do CNES bloqueia" do
    other = room_member!(room, role: "vaccinator", cbo: "322230")
    dose = record!(room, vaccine_patient!(birth_date: Date.current - 70), by: other)
    expect(validate(dose)).to eq([ :blocked, "professional_cns_not_in_cnes" ])
  end

  it "vínculo do mesmo CNS em outro CNES não vale" do
    cnes_snapshot!(bonds: [ { cnes: "7654321", cbo_code: "322205", cns: vaccinator.professional.cns, cpf: nil, ine: nil } ])
    dose = record!(room, vaccine_patient!(birth_date: Date.current - 70), by: vaccinator)
    expect(validate(dose)).to eq([ :blocked, "professional_cns_not_in_cnes" ])
  end

  it "sem retrato do CNES bloqueia" do
    CnesSnapshot.delete_all
    dose = record!(room, vaccine_patient!(birth_date: Date.current - 70), by: vaccinator)
    expect(validate(dose)).to eq([ :blocked, "professional_cns_not_in_cnes" ])
  end

  it "com cadsus_lookup: CPF não achado bloqueia; CADSUS fora do ar só adia" do
    enable_cadsus!(city)
    dose = record!(room, vaccine_patient!(birth_date: Date.current - 70), by: vaccinator)
    allow(Cadsus::Client).to receive(:for).and_return(double(lookup: nil))
    expect(validate(dose)).to eq([ :blocked, "patient_identity_unverified" ])
    allow(Cadsus::Client).to receive(:for).and_raise(Cadsus::Unavailable)
    expect(validate(dose)).to eq(:retry_later)
    expect(dose.rnds_outbox_entries.first.reload.identity_checked_at).to be_nil
  end

  it "CADSUS que confirma grava identity_checked_at e não é consultado de novo" do
    enable_cadsus!(city)
    dose = record!(room, vaccine_patient!(birth_date: Date.current - 70), by: vaccinator)
    client = double(lookup: Cadsus::Record.new(cns: "1", birth_date: Date.current, sex: "female"))
    allow(Cadsus::Client).to receive(:for).and_return(client)
    expect(validate(dose)).to eq(:ok)
    expect(dose.rnds_outbox_entries.first.reload.identity_checked_at).to be_present
    allow(Cadsus::Client).to receive(:for).and_raise(Cadsus::Unavailable)
    expect(validate(dose)).to eq(:ok)
  end

  it "paciente só com CNS não consulta o CADSUS (a consulta é por CPF)" do
    enable_cadsus!(city)
    dose = record!(room, vaccine_patient!(birth_date: Date.current - 70, cpf: false, cns: true), by: vaccinator)
    expect(Cadsus::Client).not_to receive(:for)
    expect(validate(dose)).to eq(:ok)
  end

  it "sem cadsus_lookup não consulta o CADSUS" do
    dose = record!(room, vaccine_patient!(birth_date: Date.current - 70), by: vaccinator)
    expect(Cadsus::Client).not_to receive(:for)
    expect(validate(dose)).to eq(:ok)
  end

  it "o motivo é só o código e todos estão em BLOCK_REASONS" do
    other = room_member!(room, role: "vaccinator", cbo: "322230")
    dose = record!(room, vaccine_patient!(birth_date: Date.current - 70, cpf: false, cns: false), by: other)
    _tag, reason = validate(dose)
    expect(Vaccination::Catalog::BLOCK_REASONS).to include(reason)
    expect(reason).not_to match(/\d{11}|\d{15}/)
  end
end
