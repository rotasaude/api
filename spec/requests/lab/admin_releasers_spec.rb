require "rails_helper"

# Contrato §3: liberadores com conselho do laboratório; um RT e um substituto
# ativos por laboratório; token do middleware mostrado uma vez, só o hash fica.
RSpec.describe "Laboratório — liberadores e token", type: :request do
  before { lab_city! }

  let(:provider) { lab_provider! }
  let(:admin) { lab_admin! }

  def releaser_user(council:)
    staff_with("bio-#{SecureRandom.hex(3)}@cidade.gov.br", "lab_releaser").tap do |user|
      Professional.create!(user: user, professional_name: "Bio #{SecureRandom.hex(2)}", council: council, council_state: "PR",
                           registration_number: (SecureRandom.random_number(90_000) + 10_000).to_s, cns: Professionals::Cns.generate(user.id))
    end
  end

  it "liga com RT, recusa RT repetido, conselho fora e sem perfil; encerra" do
    stepped_up!(admin)
    bio = releaser_user(council: "CRBM")
    json_post "/lab/admin/releasers", user_id: bio.id, provider_id: provider.id, technical_lead: true, technical_deputy: false
    expect(response).to have_http_status(:created)
    expect(json_body).to include("user_id" => bio.id, "council" => "CRBM", "council_uf" => "PR", "technical_lead" => true, "email" => bio.email_address)
    other = releaser_user(council: "CRF")
    json_post "/lab/admin/releasers", user_id: other.id, provider_id: provider.id, technical_lead: true, technical_deputy: false
    expect(json_body["error"]).to eq("lead_taken")
    nurse = releaser_user(council: "COREN")
    json_post "/lab/admin/releasers", user_id: nurse.id, provider_id: provider.id, technical_lead: false, technical_deputy: false
    expect(json_body["error"]).to eq("council_missing")
    bare = staff_with("semperfil-#{SecureRandom.hex(2)}@cidade.gov.br", "lab_releaser")
    json_post "/lab/admin/releasers", user_id: bare.id, provider_id: provider.id, technical_lead: false, technical_deputy: false
    expect(json_body["error"]).to eq("council_missing")
    json_post "/lab/admin/releasers", user_id: staff_with("x-#{SecureRandom.hex(2)}@c.gov.br", "lab_staff").id, provider_id: provider.id,
                                      technical_lead: false, technical_deputy: false
    expect(json_body["error"]).to eq("user_missing_role")
    get "/lab/admin/releasers"
    id = json_body["releasers"].sole["id"]
    json_delete "/lab/admin/releasers/#{id}"
    expect(response).to have_http_status(:no_content)
    json_post "/lab/admin/releasers", user_id: other.id, provider_id: provider.id, technical_lead: true, technical_deputy: false
    expect(response).to have_http_status(:created)
    expect(DomainEvent.where(name: %w[lab_releaser.assigned lab_releaser.ended]).count).to eq(3)
  end

  it "token do middleware: uma vez, troca o anterior, revoga" do
    stepped_up!(admin)
    json_post "/lab/admin/providers/#{provider.id}/middleware_token"
    first = json_body["token"]
    expect(first.length).to be >= 40
    json_post "/lab/admin/providers/#{provider.id}/middleware_token"
    expect(LabMiddlewareToken.by_token(first)).to be_revoked
    expect(LabMiddlewareToken.active.where(exam_provider: provider).count).to eq(1)
    expect(LabMiddlewareToken.pluck(:token_digest)).not_to include(first)
    json_delete "/lab/admin/providers/#{provider.id}/middleware_token"
    expect(LabMiddlewareToken.active.where(exam_provider: provider)).to be_empty
    expect(DomainEvent.where(name: "lab_middleware.token_rotated").map(&:payload).first.keys).to contain_exactly("exam_provider_id")
  end

  it "B33: /professionals/pending lista quem só tem lab_releaser e some depois do perfil" do
    sign_in_as(admin)
    bio = staff_with("bio-#{SecureRandom.hex(3)}@cidade.gov.br", "lab_releaser")
    get "/professionals/pending"
    expect(JSON.parse(response.body)["users"]).to include({ "user_id" => bio.id, "email_address" => bio.email_address, "status" => "missing_profile" })
    Professional.create!(user: bio, professional_name: "Bio", council: "CRBM", council_state: "PR", registration_number: "55555",
                         cns: Professionals::Cns.generate(bio.id))
    get "/professionals/pending"
    expect(JSON.parse(response.body)["users"].map { |u| u["user_id"] }).not_to include(bio.id)
  end
end
