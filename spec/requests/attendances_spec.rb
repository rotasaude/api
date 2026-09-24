require "rails_helper"

RSpec.describe "Attendances", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let(:verifier) { user_with("atendente@cidade.gov.br", "citizen_verifier") }
  let(:unit) { create_unit }
  def body = JSON.parse(response.body)

  def user_with(email, role)
    User.create!(email_address: email, password: "senha-segura-123").tap do |u|
      Membership.create!(user: u, role: role, granted_at: Time.current)
    end
  end

  def check_in!(citizen, triage, checked_in_at: Time.current)
    travel_to(checked_in_at) do
      Attendances::CheckIn.call(cpf: citizen.cpf, code: Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code),
                                health_unit_id: unit.id, document_checked: false, by: verifier)
                          .payload[:attendance]
    end
  end

  it "lista de abertos da unidade, ordenada por prioridade e depois por chegada" do
    urgent_citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    calm_early_citizen = Citizen.create!(cpf: "11144477735", phone: "+5541911112222")
    calm_late_citizen = Citizen.create!(cpf: "93541134780", phone: "+5541933334444")

    urgent = completed_web_triage_for(urgent_citizen).tap { |t| t.update_columns(priority: 1) }
    calm_early = completed_web_triage_for(calm_early_citizen).tap { |t| t.update_columns(priority: 9) }
    calm_late = completed_web_triage_for(calm_late_citizen).tap { |t| t.update_columns(priority: 9) }

    check_in!(calm_early_citizen, calm_early, checked_in_at: 10.minutes.ago)
    check_in!(calm_late_citizen, calm_late, checked_in_at: 5.minutes.ago)
    check_in!(urgent_citizen, urgent, checked_in_at: 1.minute.ago)

    sign_in_as(verifier)
    get "/attendance/units/#{unit.id}/open"
    expect(response).to have_http_status(:ok)
    expect(body["attendances"].map { |a| a["cpf_masked"] })
      .to eq([ urgent_citizen.cpf_masked, calm_early_citizen.cpf_masked, calm_late_citizen.cpf_masked ])
    expect(body["attendances"].first).to include("protocol_name" => urgent.protocol_name, "priority" => 1)
  end

  it "unidade inexistente: 404" do
    sign_in_as(verifier)
    get "/attendance/units/999999/open"
    expect(response).to have_http_status(:not_found)
  end

  it "encerra com cada desfecho" do
    sign_in_as(verifier)

    cpfs = { "discharged" => "52998224725", "left" => "93541134780" }
    [ "discharged", "left" ].each do |outcome|
      citizen = Citizen.create!(cpf: cpfs.fetch(outcome), phone: "+554199988#{rand(1000..9999)}")
      triage = completed_web_triage_for(citizen)
      attendance = check_in!(citizen, triage)

      json_post "/attendance/attendances/#{attendance.id}/close", outcome: outcome
      expect(response).to have_http_status(:ok)
      expect(body["attendance"]).to include("status" => "closed", "outcome" => outcome)
    end

    referral_citizen = Citizen.create!(cpf: "11144477735", phone: "+5541911112222")
    referral_triage = completed_web_triage_for(referral_citizen)
    referral_attendance = check_in!(referral_citizen, referral_triage)
    other_unit = create_unit("UPA Norte", kind: "upa")

    json_post "/attendance/attendances/#{referral_attendance.id}/close", outcome: "referred",
                                                                         referral_unit_id: other_unit.id
    expect(response).to have_http_status(:ok)
    expect(body["attendance"]).to include("status" => "closed", "outcome" => "referred",
                                          "referral_unit_name" => other_unit.name)
  end

  it "encaminhado sem destino e sem descrição: referral_required" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    triage = completed_web_triage_for(citizen)
    attendance = check_in!(citizen, triage)
    sign_in_as(verifier)

    json_post "/attendance/attendances/#{attendance.id}/close", outcome: "referred"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body["error"]).to eq("referral_required")
  end

  it "encerrar atendimento já encerrado: 409 already_closed" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    triage = completed_web_triage_for(citizen)
    attendance = check_in!(citizen, triage)
    sign_in_as(verifier)

    json_post "/attendance/attendances/#{attendance.id}/close", outcome: "left"
    expect(response).to have_http_status(:ok)

    json_post "/attendance/attendances/#{attendance.id}/close", outcome: "left"
    expect(response).to have_http_status(:conflict)
    expect(body["error"]).to eq("already_closed")
  end

  it "atendimento inexistente: 404" do
    sign_in_as(verifier)
    json_post "/attendance/attendances/999999/close", outcome: "left"
    expect(response).to have_http_status(:not_found)
  end

  it "atendimento encerrado some da lista de abertos" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    triage = completed_web_triage_for(citizen)
    attendance = check_in!(citizen, triage)
    sign_in_as(verifier)

    json_post "/attendance/attendances/#{attendance.id}/close", outcome: "left"
    expect(response).to have_http_status(:ok)

    get "/attendance/units/#{unit.id}/open"
    expect(body["attendances"]).to eq([])
  end
end
