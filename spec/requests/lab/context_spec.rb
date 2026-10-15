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

  it "B32: admin sem laboratório municipal → 200 com labs vazio" do
    [ lab, other ].each { |p| p.update!(active: false) }
    sign_in_as(lab_admin!)
    get "/lab/context"
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("labs" => [], "releaser_of" => [], "council" => nil)
  end

  it "admin ou UBS que coleta que também é liberador: todos os laboratórios ∪ os do liberador" do
    admin_releaser = lab_releaser!(lab).tap { |u| Membership.create!(user: u, role: "municipal_admin", granted_at: Time.current) }
    unit = create_unit("UBS Coletora Liberadora").tap { |u| u.update!(collects_samples: true) }
    doctor_releaser = doctor!(unit).tap do |u|
      Membership.create!(user: u, role: "lab_releaser", granted_at: Time.current)
      LabReleaser.create!(user: u, exam_provider: lab)
    end
    [ admin_releaser, doctor_releaser ].each do |user|
      sign_in_as(user)
      get "/lab/context"
      expect(json_body["labs"].map { |l| l["id"] }).to eq([ lab.id, other.id ])
      expect(json_body["releaser_of"]).to eq([ lab.id ])
    end
  end
end
