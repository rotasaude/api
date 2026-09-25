require "rails_helper"

RSpec.describe "Attendance in citizen history", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let!(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:verifier) do
    User.create!(email_address: "atendente@cidade.gov.br", password: "senha-segura-123").tap do |u|
      Membership.create!(user: u, role: "citizen_verifier", granted_at: Time.current)
    end
  end
  def body = JSON.parse(response.body)

  def check_in!(triage, unit)
    code = Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code)
    Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: unit.id, document_checked: false,
                              by: verifier).payload.fetch(:attendance)
  end

  it "sem atendimento: attendance null e check_in_available true" do
    triage = completed_web_triage_for(citizen)
    sign_in_citizen("+5541998765432")

    get "/citizen/triages/#{triage.id}"
    expect(body["attendance"]).to be_nil
    expect(body["check_in_available"]).to be(true)
  end

  it "depois do check-in: attendance.status open e unit_name" do
    unit = create_unit
    triage = completed_web_triage_for(citizen)
    check_in!(triage, unit)
    sign_in_citizen("+5541998765432")

    get "/citizen/triages/#{triage.id}"
    expect(body["attendance"]).to include("status" => "waiting", "unit_name" => unit.name)
    expect(body["check_in_available"]).to be(false)
  end

  it "depois de encerrar como encaminhado: outcome referred com referral_unit_name e referral_note" do
    unit = create_unit
    referral_unit = create_unit("UPA Norte", kind: "upa")
    triage = completed_web_triage_for(citizen)
    attendance = check_in!(triage, unit)
    Attendances::Close.call(attendance: attendance, outcome: "referred", referral_unit_id: referral_unit.id,
                            referral_note: "encaminhado para avaliação", by: verifier)
    sign_in_citizen("+5541998765432")

    get "/citizen/triages/#{triage.id}"
    expect(body["attendance"]).to include("status" => "closed", "outcome" => "referred",
                                          "referral_unit_name" => referral_unit.name,
                                          "referral_note" => "encaminhado para avaliação")
    expect(body["attendance"]["closed_at"]).to be_present
    expect(body["check_in_available"]).to be(false)
  end

  it "triagem de outro par no histórico completo de um verificado: check_in_available false" do
    Citizens::Verify.record!(citizen: citizen, by: verifier)
    other = Citizen.create!(cpf: citizen.cpf, phone: "+5541911112222")
    other_triage = completed_web_triage_for(other)
    sign_in_citizen("+5541998765432")

    get "/citizen/triages", params: { citizen_id: citizen.id }
    entry = body["triages"].find { |t| t["id"] == other_triage.id }
    expect(entry).to be_present
    expect(entry["check_in_available"]).to be(false)
  end

  it "triagem antiga: check_in_available false" do
    triage = completed_web_triage_for(citizen, completed_at: 4.days.ago)
    sign_in_citizen("+5541998765432")

    get "/citizen/triages/#{triage.id}"
    expect(body["check_in_available"]).to be(false)
  end
end
