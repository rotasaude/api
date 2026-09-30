require "rails_helper"

# ADR 0025 (D6): analyst é só leitura analítica — conceder não pede step-up.
RSpec.describe "Conceder analyst", type: :request do
  let(:admin) do
    staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  let(:person) { staff_with("pessoa-#{SecureRandom.hex(3)}@cidade.gov.br", "viewer") }

  it "municipal_admin concede sem janela de step-up" do
    sign_in_as(admin)
    post "/setup/memberships", params: { user_id: person.id, role: "analyst" }, as: :json
    expect(response).to have_http_status(:created)
    expect(person.reload.has_role?(:analyst)).to be(true)
  end
end
