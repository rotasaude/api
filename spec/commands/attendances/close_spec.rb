require "rails_helper"

RSpec.describe Attendances::Close do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:staff) { User.create!(email_address: "atendente@cidade.gov.br", password: "senha-segura-123") }
  let(:unit) { create_unit }
  let(:upa) { create_unit("UPA Norte", kind: "upa") }
  let(:attendance) do
    t = completed_web_triage_for(citizen)
    Attendance.create!(triage: t, citizen: citizen, health_unit: unit, checked_in_by_user: staff,
                       checked_in_at: Time.current, check_in_method: "code")
  end

  def close(outcome, unit_id: nil, note: nil)
    described_class.call(attendance: attendance, outcome: outcome, referral_unit_id: unit_id, referral_note: note, by: staff)
  end

  it "liberado e saiu sem atendimento" do
    expect(close("discharged")).to be_ok
    expect(attendance.reload).to have_attributes(status: "closed", outcome: "discharged", closed_by_user_id: staff.id)
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
    close("left")
    expect(described_class.call(attendance: stale, outcome: "discharged", referral_unit_id: nil, referral_note: nil,
                                by: staff).reason).to eq(:already_closed)
  end

  it "desfecho desconhecido" do
    expect(close("cured").reason).to eq(:invalid_outcome)
  end
end
