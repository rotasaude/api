require "rails_helper"

RSpec.describe "Counter code purposes" do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = TEST_CITY_A }
  after { Current.reset; travel_back; Rails.cache.clear }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:triage) { completed_web_triage_for(citizen) }

  def check_in_code
    Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code)
  end

  it "o código de check-in aponta para a triagem" do
    code = check_in_code
    match = Citizens::VerificationCodeMatch.call(cpf: citizen.cpf, code: code, purpose: "check_in")
    expect(match.payload[:triage]).to eq(triage)
  end

  it "código de check-in na validação, e o contrário, dá invalid_code" do
    code = check_in_code
    expect(Citizens::VerificationCodeMatch.call(cpf: citizen.cpf, code: code).reason).to eq(:invalid_code)
    v = issue_code_for(citizen)
    expect(Citizens::VerificationCodeMatch.call(cpf: citizen.cpf, code: v, purpose: "check_in").reason).to eq(:invalid_code)
  end

  it "um código novo invalida o anterior de qualquer finalidade" do
    check_in_code
    issue_code_for(citizen)
    expect(CitizenVerificationCode.usable.where(citizen: citizen).pluck(:purpose)).to eq(["verification"])
  end

  it "só nasce para triagem concluída há 3 dias ou menos e sem atendimento" do
    old = completed_web_triage_for(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"), completed_at: 4.days.ago)
    expect(Citizens::IssueCheckInCode.call(citizen: old.conversation.citizen, triage: old).reason).to eq(:triage_too_old)
  end
end
