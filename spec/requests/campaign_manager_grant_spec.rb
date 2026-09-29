require "rails_helper"

# ADR 0024: campaign_manager é privilegiado — conceder pede step-up, como os
# demais de Membership::PRIVILEGED_ROLES (SetupController#privileged_role?).
RSpec.describe "Conceder campaign_manager", type: :request do
  let(:admin) do
    staff_with("admin@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  let(:person) { staff_with("comunicacao@cidade.gov.br", "viewer") }

  it "sem step-up: 401 mfa_required e nada é concedido" do
    sign_in_as(admin)
    post "/setup/memberships", params: { user_id: person.id, role: "campaign_manager" }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(JSON.parse(response.body)).to eq("error" => "mfa_required")
    expect(person.reload.has_role?(:campaign_manager)).to be(false)
  end

  it "com step-up: 201 e o papel vale" do
    sign_in_as(admin).update!(mfa_verified_at: Time.current)
    post "/setup/memberships", params: { user_id: person.id, role: "campaign_manager" }, as: :json
    expect(response).to have_http_status(:created)
    expect(person.reload.has_role?(:campaign_manager)).to be(true)
  end
end
