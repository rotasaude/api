require "rails_helper"

# Dashboard D1: onde a sessão atua e o conselho de quem libera.
RSpec.describe "Laboratório — contexto da sessão", type: :request do
  before { lab_city! }

  let!(:lab) { lab_provider!(name: "Laboratório A") }
  let!(:other) { lab_provider!(name: "Laboratório B") }

  it "técnica vê todos; liberador vê o seu e o conselho; UBS que coleta vê os laboratórios; estranho 403" do
    sign_in_as(lab_staff!)
    get "/lab/context"
    expect(json_body).to eq("labs" => [ { "id" => lab.id, "name" => "Laboratório A" }, { "id" => other.id, "name" => "Laboratório B" } ],
                            "releaser_of" => [], "council" => nil)
    releaser = lab_releaser!(lab, council: "CRBM")
    sign_in_as(releaser)
    get "/lab/context"
    expect(json_body).to eq("labs" => [ { "id" => lab.id, "name" => "Laboratório A" } ], "releaser_of" => [ lab.id ], "council" => "CRBM")
    unit = create_unit("UBS Coletora").tap { |u| u.update!(collects_samples: true) }
    sign_in_as(doctor!(unit))
    get "/lab/context"
    expect(json_body["labs"].size).to eq(2)
    sign_in_as(doctor!(create_unit("UBS Sem Coleta")))
    get "/lab/context"
    expect(json_body["error"]).to eq("missing_role")
  end

  it "B32: papel de laboratório sem laboratório → 200 com labs vazio" do
    lonely = lab_releaser!(lab)
    LabReleaser.find_by!(user_id: lonely.id).update!(ended_at: Time.current)
    [ lab, other ].each { |p| p.update!(active: false) }
    [ lab_staff!, lonely ].each do |user|
      sign_in_as(user)
      get "/lab/context"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("labs" => [], "releaser_of" => [])
    end
  end
end
