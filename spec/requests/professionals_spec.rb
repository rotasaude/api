require "rails_helper"

RSpec.describe "Professionals", type: :request do
  def json = JSON.parse(response.body)

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:attrs) do
    { professional_name: "Helena Duarte", council: "CRM", council_state: "PR",
      registration_number: "12345", cns: "700000000000005" }
  end

  def create_profile!(user = doctor)
    Current.set(city: TEST_CITY_A) { Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin) }
           .payload[:professional]
  end

  describe "POST /professionals" do
    it "admin cria; resposta com CNS completo" do
      sign_in_as(admin)
      json_post "/professionals", attrs.merge(user_id: doctor.id)
      expect(response).to have_http_status(:created)
      expect(json["professional"]).to include("user_id" => doctor.id, "cns" => "700000000000005",
                                              "cns_masked" => "*** **** **** 0005")
    end

    it "usuário sem o papel: 422 user_missing_role" do
      sign_in_as(admin)
      json_post "/professionals", attrs.merge(user_id: admin.id)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("user_missing_role")
    end

    it "campo inválido: 422 invalid com fields" do
      sign_in_as(admin)
      json_post "/professionals", attrs.merge(user_id: doctor.id, cns: "1")
      expect(json).to include("error" => "invalid", "fields" => [ "cns" ])
    end

    it "valor não escalar: 422 invalid, nada criado" do
      sign_in_as(admin)
      json_post "/professionals", attrs.merge(user_id: doctor.id, professional_name: { "x" => 1 })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(Professional.count).to eq(0)
    end
  end

  describe "GET /professionals e /professionals/:id" do
    it "a lista mascara o CNS e não traz contato; a ficha traz tudo" do
      p = create_profile!
      sign_in_as(admin)
      get "/professionals"
      row = json["professionals"].sole
      expect(row).to include("id" => p.id, "cns_masked" => "*** **** **** 0005", "links" => [])
      expect(row).not_to include("cns", "phone", "contact_email")

      get "/professionals/#{p.id}"
      expect(json["professional"]).to include("cns" => "700000000000005", "phone" => nil)
    end

    it "id inexistente: 404" do
      sign_in_as(admin)
      get "/professionals/#{SecureRandom.uuid}"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /professionals/:id" do
    it "admin edita; user_id é field_not_editable" do
      p = create_profile!
      sign_in_as(admin)
      json_post "/professionals/#{p.id}", council_state: "SC"
      expect(response).to have_http_status(:ok)
      expect(p.reload.council_state).to eq("SC")

      json_post "/professionals/#{p.id}", user_id: admin.id
      expect(json).to include("error" => "field_not_editable", "fields" => [ "user_id" ])
    end

    it "conselho em uso por vínculo ativo (D9): 422 council_in_use" do
      p = create_profile!
      unit = create_unit
      Current.set(city: TEST_CITY_A) do
        ProfessionalLink.create!(professional: p, health_unit: unit, cbo_code: "225125", started_at: Time.current,
                                 started_by_user: admin)
      end
      sign_in_as(admin)
      json_post "/professionals/#{p.id}", council: "COREN"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("council_in_use")
      expect(p.reload.council).to eq("CRM")
    end
  end

  describe "GET /professionals/pending" do
    it "lista quem tem o papel sem perfil ou sem vínculo" do
      create_profile!
      novato = staff_with("novato@cidade.gov.br", "health_professional")
      sign_in_as(admin)
      get "/professionals/pending"
      expect(json["users"]).to contain_exactly(
        { "user_id" => doctor.id, "email_address" => doctor.email_address, "status" => "missing_link" },
        { "user_id" => novato.id, "email_address" => novato.email_address, "status" => "missing_profile" }
      )
    end
  end

  describe "me" do
    it "sem perfil: 404 no_profile" do
      sign_in_as(doctor)
      get "/professionals/me"
      expect(response).to have_http_status(:not_found)
      expect(json["error"]).to eq("no_profile")
    end

    it "lê o próprio perfil completo, com vínculos e turnos" do
      create_profile!
      sign_in_as(doctor)
      get "/professionals/me"
      expect(json["professional"]).to include("cns" => "700000000000005")
      expect(json).to include("links" => [], "shifts" => [])
    end

    it "edita nome e contato" do
      p = create_profile!
      sign_in_as(doctor)
      json_post "/professionals/me", professional_name: "Helena D. Moreira", contact_email: "helena@ubs.org"
      expect(response).to have_http_status(:ok)
      expect(p.reload).to have_attributes(professional_name: "Helena D. Moreira", contact_email: "helena@ubs.org")
    end

    it "chave fora de nome/contato: 422 field_not_editable, nada muda" do
      p = create_profile!
      sign_in_as(doctor)
      json_post "/professionals/me", professional_name: "Outro", cns: "100000000000007", user_id: admin.id
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json).to include("error" => "field_not_editable", "fields" => %w[cns user_id])
      expect(p.reload.professional_name).to eq("Helena Duarte")
    end

    it "traz o turno em andamento; não traz o turno já encerrado" do
      now = Time.current
      p = create_profile!
      unit = create_unit
      link = ProfessionalLink.create!(professional: p, health_unit: unit, cbo_code: "225125",
                                      started_at: now - 1.day, started_by_user: admin)
      in_progress = ProfessionalShift.create!(professional_link: link, professional: p, created_by_user: admin,
                                              starts_at: now - 1.hour, ends_at: now + 3.hours)
      ProfessionalShift.create!(professional_link: link, professional: p, created_by_user: admin,
                                starts_at: now - 4.hours, ends_at: now - 1.hour)
      sign_in_as(doctor)
      get "/professionals/me"
      expect(json["shifts"].map { |s| s["id"] }).to contain_exactly(in_progress.id)
    end
  end

  describe "POST /professionals conflitos" do
    it "segundo perfil para o mesmo usuário: 409 already_exists" do
      create_profile!
      sign_in_as(admin)
      json_post "/professionals", attrs.merge(user_id: doctor.id)
      expect(response).to have_http_status(:conflict)
      expect(json["error"]).to eq("already_exists")
    end

    it "CNS já usado: 409 cns_taken" do
      create_profile!
      other = staff_with("outro@cidade.gov.br", "health_professional")
      sign_in_as(admin)
      json_post "/professionals", attrs.merge(user_id: other.id, registration_number: "99999")
      expect(response).to have_http_status(:conflict)
      expect(json["error"]).to eq("cns_taken")
    end

    it "número de registro já usado: 409 registration_taken" do
      create_profile!
      other = staff_with("outro@cidade.gov.br", "health_professional")
      sign_in_as(admin)
      json_post "/professionals", attrs.merge(user_id: other.id, cns: "100000000000007")
      expect(response).to have_http_status(:conflict)
      expect(json["error"]).to eq("registration_taken")
    end
  end

  describe "só o municipal_admin usa as rotas de admin" do
    (Membership::ROLES - %w[municipal_admin]).each do |role|
      it "#{role}: 403 em todas" do
        p = create_profile!
        sign_in_as(staff_with("#{role}@cidade.gov.br", role))
        get "/professionals"
        expect(response).to have_http_status(:forbidden)
        get "/professionals/pending"
        expect(response).to have_http_status(:forbidden)
        get "/professionals/#{p.id}"
        expect(response).to have_http_status(:forbidden)
        json_post "/professionals", attrs.merge(user_id: doctor.id)
        expect(response).to have_http_status(:forbidden)
        json_post "/professionals/#{p.id}", council_state: "SC"
        expect(response).to have_http_status(:forbidden)
        expect(p.reload.council_state).to eq("PR")
      end
    end
  end
end
