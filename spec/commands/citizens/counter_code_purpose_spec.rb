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
  it "triagem em andamento ou fora da web: triage_not_eligible e nenhum código nasce (F-13.1)" do
    not_web = completed_web_triage_for(citizen) # também cria o protocolo padrão
    other = Citizen.create!(cpf: "11144477735", phone: "+5541911112222")
    started = Citizens::StartConversation.call(citizen: other, consent_version: Consents.current_version, session_id: "s")
                                         .payload
    in_progress = started[:triage]
    expect(in_progress.status).to eq("in_progress")
    expect(Citizens::IssueCheckInCode.call(citizen: other, triage: in_progress).reason).to eq(:triage_not_eligible)

    not_web.conversation.update_columns(channel: "whatsapp")
    expect(Citizens::IssueCheckInCode.call(citizen: citizen, triage: not_web.reload).reason).to eq(:triage_not_eligible)
    expect(CitizenVerificationCode.count).to eq(0)
  end
end
