require "rails_helper"

RSpec.describe "GET /professionals/cbo", type: :request do
  it "admin recebe a lista vigente" do
    sign_in_as(staff_with("admin@cidade.gov.br", "municipal_admin"))
    get "/professionals/cbo"
    codes = JSON.parse(response.body)["cbo"].map { |e| e["code"] }
    expect(codes).to include("225125", "223505", "322205")
  end

  it "outro papel: 403" do
    sign_in_as(staff_with("medica@cidade.gov.br", "health_professional"))
    get "/professionals/cbo"
    expect(response).to have_http_status(:forbidden)
  end
end
