# spec/requests/campaign_sms_setting_spec.rb
require "rails_helper"

RSpec.describe "Chave de SMS da cidade", type: :request do
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  let(:admin) do
    staff_with("admin@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end

  def sign_in_admin!(stepped_up: true)
    session = sign_in_as(admin)
    session.update!(mfa_verified_at: Time.current) if stepped_up
  end

  before { CityProfile.create!(name: "Curitiba") }

  it "campaign_manager e municipal_admin leem; os demais, 403" do
    %w[campaign_manager municipal_admin].each do |role|
      sign_in_as(staff_with("#{role}@cidade.gov.br", role))
      get "/campaigns/sms_setting"
      expect(body).to eq("enabled" => false, "gateway_configured" => true), role
    end
    sign_in_as(staff_with("viewer@cidade.gov.br", "viewer"))
    get "/campaigns/sms_setting"
    expect(status_and_error).to eq([ 403, "missing_role" ])
  end

  it "municipal_admin liga com step-up; evento só quando muda" do
    sign_in_admin!
    put "/campaigns/sms_setting", params: { enabled: true }, as: :json
    expect(body).to eq("enabled" => true, "gateway_configured" => true)
    put "/campaigns/sms_setting", params: { enabled: true }, as: :json
    expect(DomainEvent.where(name: "city.campaigns_sms_toggled").map(&:payload))
      .to eq([ { "enabled" => true, "by_user_id" => admin.id } ])
    expect(CityProfile.current.campaigns_sms_enabled).to be(true)
  end

  it "ligar sem provedor é permitido e a resposta avisa" do
    sign_in_admin!
    with_sms_gateway(nil) { put "/campaigns/sms_setting", params: { enabled: true }, as: :json }
    expect(body).to eq("enabled" => true, "gateway_configured" => false)
  end

  it "sem step-up: 401; campaign_manager não muda: 403; valor não booleano: 422 invalid_setting" do
    sign_in_admin!(stepped_up: false)
    put "/campaigns/sms_setting", params: { enabled: true }, as: :json
    expect(status_and_error).to eq([ 401, "mfa_required" ])

    sign_in_as(staff_with("campanhas@cidade.gov.br", "campaign_manager")).update!(mfa_verified_at: Time.current)
    put "/campaigns/sms_setting", params: { enabled: true }, as: :json
    expect(status_and_error).to eq([ 403, "missing_role" ])

    sign_in_admin!
    [ "sim", nil, 1 ].each do |value|
      put "/campaigns/sms_setting", params: { enabled: value }, as: :json
      expect(status_and_error).to eq([ 422, "invalid_setting" ]), value.inspect
    end
    expect(CityProfile.current.campaigns_sms_enabled).to be(false)
  end

  it "cidade sem city_profile: 409 city_profile_missing" do
    CityProfile.delete_all
    sign_in_admin!
    put "/campaigns/sms_setting", params: { enabled: true }, as: :json
    expect(status_and_error).to eq([ 409, "city_profile_missing" ])
  end
end
