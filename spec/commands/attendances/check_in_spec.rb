require "rails_helper"

RSpec.describe Attendances::CheckIn do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:staff) { User.create!(email_address: "atendente@cidade.gov.br", password: "senha-segura-123") }
  let(:unit) { create_unit }
  let(:triage) { completed_web_triage_for(citizen) }

  def code = Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code)

  def check_in(c, unit_id: unit.id, checked: false)
    described_class.call(cpf: citizen.cpf, code: c, health_unit_id: unit_id, document_checked: checked, by: staff)
  end

  it "abre o atendimento, consome o código e publica o evento" do
    c = code
    result = check_in(c)
    attendance = result.payload[:attendance]
    expect(attendance).to have_attributes(triage_id: triage.id, health_unit_id: unit.id, check_in_method: "code",
                                          status: "waiting")
    expect(result.payload[:verified]).to be(false)
    expect(check_in(c).reason).to eq(:code_expired)
    expect(DomainEvent.where(name: "attendance.checked_in").sole.payload.keys)
      .to match_array(%w[attendance_id triage_id appointment_id citizen_id health_unit_id checked_in_by_user_id
                          check_in_method])
  end

  it "declarado com a caixa: valida e faz check-in juntos" do
    result = check_in(code, checked: true)
    expect(result.payload[:verified]).to be(true)
    expect(citizen.reload).to be_verification_level_verified
    expect(DomainEvent.where(name: "citizen.verified").count).to eq(1)
  end

  it "se o check-in falha, a validação também não fica" do
    Attendance.create!(triage: triage, citizen: citizen, health_unit: unit, checked_in_by_user: staff,
                       checked_in_at: Time.current, check_in_method: "code")
    CitizenVerificationCode.create!(citizen: citizen, purpose: "check_in", triage: triage,
                                    code_digest: CitizenVerificationCode.digest(citizen.id, "123456"),
                                    expires_at: 10.minutes.from_now)
    expect(check_in("123456", checked: true).reason).to eq(:already_checked_in)
    expect(citizen.reload).to be_verification_level_declared
    expect(CitizenVerification.count).to eq(0)
  end

  it "unidade inativa: invalid_unit, nada criado" do
    unit.update!(active: false)
    expect(check_in(code).reason).to eq(:invalid_unit)
    expect(Attendance.count).to eq(0)
  end

  it "triagem antiga: triage_too_old" do
    c = code
    triage.update_columns(completed_at: 4.days.ago)
    expect(check_in(c).reason).to eq(:triage_too_old)
  end
end
