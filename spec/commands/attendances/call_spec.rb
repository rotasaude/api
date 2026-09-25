require "rails_helper"

RSpec.describe Attendances::Call do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:other_unit) { create_unit("UPA Norte", kind: "upa") }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:doctor2) { staff_with("medico@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  it "chama: waiting → in_care, grava quem e quando, publica evento" do
    a = waiting_attendance(citizen, unit: unit, by: reception)
    expect { described_class.call(attendance: a, health_unit_id: unit.id, by: doctor) }
      .to change { DomainEvent.where(name: "attendance.called").count }.by(1)
    expect(a.reload).to have_attributes(status: "in_care", called_by_user_id: doctor.id)
    expect(a.called_at).to be_present
  end

  it "segundo profissional recebe already_called" do
    a = waiting_attendance(citizen, unit: unit, by: reception)
    described_class.call(attendance: a, health_unit_id: unit.id, by: doctor)
    result = described_class.call(attendance: Attendance.find(a.id), health_unit_id: unit.id, by: doctor2)
    expect(result.reason).to eq(:already_called)
    expect(a.reload.called_by_user_id).to eq(doctor.id)
  end

  it "atendimento de outra unidade: wrong_unit" do
    a = waiting_attendance(citizen, unit: unit, by: reception)
    expect(described_class.call(attendance: a, health_unit_id: other_unit.id, by: doctor).reason).to eq(:wrong_unit)
  end

  describe Attendances::CallNext do
    it "chama o primeiro por prioridade e depois por chegada; fila vazia dá queue_empty" do
      calm = waiting_attendance(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"), unit: unit, by: reception)
      calm.triage.update_columns(priority: 9)
      urgent = waiting_attendance(citizen, unit: unit, by: reception)
      urgent.triage.update_columns(priority: 1)

      expect(Attendances::CallNext.call(health_unit_id: unit.id, by: doctor).payload[:attendance].id).to eq(urgent.id)
      expect(Attendances::CallNext.call(health_unit_id: unit.id, by: doctor).payload[:attendance].id).to eq(calm.id)
      expect(Attendances::CallNext.call(health_unit_id: unit.id, by: doctor).reason).to eq(:queue_empty)
    end
  end
end
