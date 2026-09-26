require "rails_helper"

RSpec.describe Attendances::Close do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:unit) { create_unit }
  let(:upa) { create_unit("UPA Norte", kind: "upa") }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:attendance) { in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor) }

  def close(outcome, unit_id: nil, note: nil)
    described_class.call(attendance: attendance, outcome: outcome, referral_unit_id: unit_id, referral_note: note, by: doctor)
  end

  it "liberado e saiu sem atendimento" do
    expect(close("discharged")).to be_ok
    expect(attendance.reload).to have_attributes(status: "closed", outcome: "discharged", closed_by_user_id: doctor.id)
    expect(DomainEvent.where(name: "attendance.closed").sole.payload).to include("outcome" => "discharged")
  end

  it "encaminhado exige destino ou descrição, e o destino precisa estar ativo" do
    expect(close("referred").reason).to eq(:referral_required)
    upa.update!(active: false)
    expect(close("referred", unit_id: upa.id).reason).to eq(:invalid_unit)
    expect(close("referred", note: "cardiologia")).to be_ok
  end

  it "encerrar duas vezes, inclusive com registro velho, dá already_closed" do
    stale = Attendance.find(attendance.id)
    close("discharged")
    expect(described_class.call(attendance: stale, outcome: "discharged", referral_unit_id: nil, referral_note: nil,
                                by: doctor).reason).to eq(:already_closed)
  end

  it "desfecho desconhecido" do
    expect(close("cured").reason).to eq(:invalid_outcome)
  end

  it "left só a partir de waiting" do
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    r = described_class.call(attendance: a, outcome: "left", referral_unit_id: nil, referral_note: nil, by: doctor)
    expect(r.reason).to eq(:invalid_transition)
    fresh = waiting_attendance(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"), unit: unit, by: reception)
    expect(described_class.call(attendance: fresh, outcome: "left", referral_unit_id: nil, referral_note: nil, by: reception))
      .to be_ok
  end

  it "desfecho clínico a partir de waiting: invalid_transition" do
    a = waiting_attendance(citizen, unit: unit, by: reception)
    r = described_class.call(attendance: a, outcome: "discharged", referral_unit_id: nil, referral_note: nil, by: doctor)
    expect(r.reason).to eq(:invalid_transition)
  end

  it "return cria pedido na própria unidade, com a nota, na mesma transação" do
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    r = described_class.call(attendance: a, outcome: "return", referral_unit_id: nil,
                             referral_note: "reavaliar em 15 dias", by: doctor)
    req = r.payload[:appointment_request]
    expect(req).to have_attributes(kind: "return", origin_unit_id: unit.id, target_unit_id: unit.id,
                                   status: "open", note: "reavaliar em 15 dias", root_triage_id: a.triage_id)
    expect(DomainEvent.where(name: "appointment_request.created").count).to eq(1)
  end

  it "referred com unidade cria pedido de encaminhamento; só com descrição não cria" do
    other = create_unit("UPA Norte", kind: "upa")
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    r = described_class.call(attendance: a, outcome: "referred", referral_unit_id: other.id, referral_note: nil, by: doctor)
    expect(r.payload[:appointment_request]).to have_attributes(kind: "referral", target_unit_id: other.id)

    b = in_care!(waiting_attendance(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"), unit: unit,
                                    by: reception), by: doctor)
    r2 = described_class.call(attendance: b, outcome: "referred", referral_unit_id: nil,
                              referral_note: "hospital estadual", by: doctor)
    expect(r2.payload[:appointment_request]).to be_nil
  end

  it "falha ao criar o pedido desfaz o encerramento" do
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    allow(AppointmentRequest).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")
    expect do
      described_class.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil, by: doctor)
    end.to raise_error(ActiveRecord::StatementInvalid)
    expect(a.reload.status).to eq("in_care")
  end
end
