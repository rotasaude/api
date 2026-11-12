require "rails_helper"

# Módulo 33 (ADR 0051; contrato §7, Q6/Q7/Q12): setores, respondentes,
# assuntos, prazos e opções.
RSpec.describe "Ouvidoria — configuração", type: :request do
  let!(:city) { ombudsman_city! }
  let(:admin) { ombudsman_admin! }
  let(:ouvidor) { ombudsman! }
  let(:technician) { ombudsman_staff! }

  def unit!(name = "UBS #{SecureRandom.hex(3)}", kind: "ubs") = HealthUnit.create!(name: name, kind: kind)
  def candidate!(*roles) = staff_with("cand-#{SecureRandom.hex(3)}@cidade.gov.br", *(roles.presence || [ "ombudsman_responder" ]))

  describe "/departments (sem portão, Q12)" do
    it "o administrador cria e renomeia; nome repetido sem distinguir caixa → 409 name_taken" do
      sign_in_as(admin)
      json_post "/departments", name: "  Vigilância Sanitária "
      expect(response).to have_http_status(:created)
      expect(json_body).to include("name" => "Vigilância Sanitária", "active" => true)
      id = json_body["id"]

      json_post "/departments", name: "vigilância sanitária"
      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to eq("name_taken")

      json_patch "/departments/#{id}", name: "Vigilância Epidemiológica"
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => id, "name" => "Vigilância Epidemiológica")

      json_post "/departments", name: "Outro"
      json_patch "/departments/#{json_body['id']}", name: "VIGILÂNCIA EPIDEMIOLÓGICA"
      expect(json_body["error"]).to eq("name_taken")
    end

    it "valida o nome (2..80 depois do strip) e o active" do
      sign_in_as(admin)
      json_post "/departments", name: " a "
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "name")
      json_post "/departments", {}
      expect(json_body["path"]).to eq("name")
      json_post "/departments", name: "x" * 81
      expect(json_body["path"]).to eq("name")

      dept = department!
      json_patch "/departments/#{dept.id}", active: "false"
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["path"]).to eq("active")
      expect(dept.reload.active).to be(true)
    end

    it "desativa mesmo com encaminhamento pendente e lista com ?active=true" do
      dept = department!("Setor A")
      department!("Setor B")
      manifestation = manifestation!
      forwarding = OmbudsmanForwarding.create!(ombudsman_manifestation: manifestation, department: dept, extract: "x" * 30,
                                               due_on: Date.current + 20, state: "pending", created_by_user: technician)
      sign_in_as(admin)
      json_patch "/departments/#{dept.id}", active: false
      expect(response).to have_http_status(:ok)
      expect(json_body["active"]).to be(false)
      expect(forwarding.reload.state).to eq("pending")

      get "/departments"
      expect(json_body["items"].map { |i| i["name"] }).to eq([ "Setor A", "Setor B" ])
      expect(json_body["items"].first.keys).to contain_exactly("id", "name", "active")
      get "/departments", params: { active: "true" }
      expect(json_body["items"].map { |i| i["name"] }).to eq([ "Setor B" ])
    end

    it "técnico e ouvidor leem e não escrevem (403); respondente nem lê; id inexistente → 404" do
      dept = department!
      sign_in_as(technician)
      get "/departments"
      expect(response).to have_http_status(:ok)
      json_post "/departments", name: "Novo setor"
      expect(response).to have_http_status(:forbidden)
      json_patch "/departments/#{dept.id}", active: false
      expect(response).to have_http_status(:forbidden)
      expect(dept.reload.active).to be(true)

      sign_in_as(ouvidor)
      get "/departments"
      expect(response).to have_http_status(:ok)
      json_post "/departments", name: "Novo setor"
      expect(response).to have_http_status(:forbidden)

      sign_in_as(candidate!)
      get "/departments"
      expect(response).to have_http_status(:forbidden)

      sign_in_as(admin)
      json_patch "/departments/#{SecureRandom.uuid}", active: false
      expect(response).to have_http_status(:not_found)
      json_patch "/departments/nao-e-uuid", active: false
      expect(response).to have_http_status(:not_found)
    end

    it "ouvidoria desligada: /ombudsman/* → 403 feature_disabled e /departments segue respondendo" do
      Platform::Features.set!(city: city, key: "ombudsman", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(ouvidor)
      %w[responders responder_candidates subjects settings options].each do |path|
        get "/ombudsman/#{path}"
        expect(response).to have_http_status(:forbidden)
        expect(json_body).to eq("error" => "feature_disabled", "feature" => "ombudsman")
      end
      get "/departments"
      expect(response).to have_http_status(:ok)
      sign_in_as(admin)
      json_post "/departments", name: "Com a ouvidoria desligada"
      expect(response).to have_http_status(:created)
    end
  end

  describe "/ombudsman/responders" do
    it "o ouvidor cadastra respondente num setor e numa unidade, lista e desliga" do
      sign_in_as(ouvidor)
      dept = department!("Setor R")
      unit = unit!("UBS R")
      user = candidate!

      json_post "/ombudsman/responders", user_id: user.id, department_id: dept.id
      expect(response).to have_http_status(:created)
      expect(json_body).to include("active" => true,
                                   "user" => { "id" => user.id, "email" => user.email_address, "name" => user.email_address },
                                   "destination" => { "kind" => "department", "id" => dept.id, "name" => "Setor R" })
      department_row = json_body["id"]

      json_post "/ombudsman/responders", user_id: user.id, health_unit_id: unit.id
      expect(response).to have_http_status(:created)
      expect(json_body["destination"]).to eq("kind" => "health_unit", "id" => unit.id, "name" => "UBS R")

      get "/ombudsman/responders"
      expect(json_body["items"].map { |i| i["destination"]["kind"] }).to eq(%w[department health_unit])

      json_patch "/ombudsman/responders/#{department_row}", active: false
      expect(response).to have_http_status(:ok)
      expect(json_body["active"]).to be(false)
      expect(OmbudsmanResponder.find(department_row).active).to be(false)
      expect(Ombudsman::Access.responder_ids_for(department_id: dept.id)).to eq([])
      json_patch "/ombudsman/responders/#{department_row}", active: true
      expect(Ombudsman::Access.responder_ids_for(department_id: dept.id)).to eq([ user.id ])
    end

    it "usa o nome do perfil profissional quando existe" do
      unit = unit!
      user = candidate!
      link_professional!(user, unit)
      sign_in_as(ouvidor)
      json_post "/ombudsman/responders", user_id: user.id, health_unit_id: unit.id
      expect(json_body.dig("user", "name")).to eq(user.professional.professional_name)
    end

    it "sem o papel ombudsman_responder → 422 missing_responder_role (path user_id); papel revogado também" do
      sign_in_as(ouvidor)
      dept = department!
      other = staff_with("sem-papel@cidade.gov.br", "viewer")
      json_post "/ombudsman/responders", user_id: other.id, department_id: dept.id
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "missing_responder_role", "path" => "user_id")

      revoked = candidate!
      revoked.memberships.each(&:revoke!)
      json_post "/ombudsman/responders", user_id: revoked.id, department_id: dept.id
      expect(json_body["error"]).to eq("missing_responder_role")

      json_post "/ombudsman/responders", user_id: SecureRandom.uuid, department_id: dept.id
      expect(json_body["error"]).to eq("missing_responder_role")
      expect(OmbudsmanResponder.count).to eq(0)
    end

    it "destino: exatamente um, existente e ativo; repetido (mesmo desligado) → 409 already_responder" do
      sign_in_as(ouvidor)
      user = candidate!
      dept = department!
      unit = unit!
      json_post "/ombudsman/responders", user_id: user.id
      expect(json_body).to include("error" => "invalid_request", "path" => "department_id")
      json_post "/ombudsman/responders", user_id: user.id, department_id: dept.id, health_unit_id: unit.id
      expect(response).to have_http_status(:unprocessable_content)
      json_post "/ombudsman/responders", user_id: user.id, health_unit_id: SecureRandom.uuid
      expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")
      dept.update!(active: false)
      json_post "/ombudsman/responders", user_id: user.id, department_id: dept.id
      expect(json_body).to include("error" => "invalid_request", "path" => "department_id")
      json_post "/ombudsman/responders", user_id: "x", department_id: department!.id
      expect(json_body["path"]).to eq("user_id")

      json_post "/ombudsman/responders", user_id: user.id, health_unit_id: unit.id
      expect(response).to have_http_status(:created)
      json_post "/ombudsman/responders", user_id: user.id, health_unit_id: unit.id
      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to eq("already_responder")
      json_patch "/ombudsman/responders/#{OmbudsmanResponder.first.id}", active: false
      json_post "/ombudsman/responders", user_id: user.id, health_unit_id: unit.id
      expect(response).to have_http_status(:conflict)
      json_patch "/ombudsman/responders/#{OmbudsmanResponder.first.id}", active: "no"
      expect(json_body["path"]).to eq("active")
      json_patch "/ombudsman/responders/#{SecureRandom.uuid}", active: true
      expect(response).to have_http_status(:not_found)
    end

    it "só o ouvidor: técnico, administrador e respondente → 403" do
      [ technician, admin, candidate! ].each do |user|
        sign_in_as(user)
        get "/ombudsman/responders"
        expect(response).to have_http_status(:forbidden)
        expect(json_body["error"]).to eq("missing_role")
        json_post "/ombudsman/responders", user_id: user.id, department_id: department!.id
        expect(response).to have_http_status(:forbidden)
        get "/ombudsman/responder_candidates"
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "/ombudsman/responder_candidates (Q7)" do
    it "lista só quem tem o papel de respondente ativo e conta ativa" do
      with_role = candidate!
      without_role = staff_with("tecnico-so@cidade.gov.br", "ombudsman_staff")
      revoked = candidate!
      revoked.memberships.each(&:revoke!)
      deactivated = candidate!
      deactivated.update!(deactivated_at: Time.current)
      sign_in_as(ouvidor)

      get "/ombudsman/responder_candidates"
      expect(response).to have_http_status(:ok)
      expect(json_body["items"]).to eq([ { "id" => with_role.id, "name" => with_role.email_address, "email" => with_role.email_address } ])
      ids = json_body["items"].map { |i| i["id"] }
      expect(ids).not_to include(without_role.id, revoked.id, deactivated.id)
    end
  end

  describe "/ombudsman/subjects" do
    it "lê a semente (técnico), cria assunto e subassunto, recusa neto (too_deep) e nome repetido" do
      sign_in_as(technician)
      expect(Ombudsman::Settings).to receive(:ensure_defaults!).at_least(:once).and_call_original
      get "/ombudsman/subjects"
      expect(response).to have_http_status(:ok)
      tree = json_body["items"]
      expect(tree.map { |s| s["name"] }).to eq(OmbudsmanSubject::DEFAULT_TREE.map(&:first))
      expect(tree.first).to include("active" => true)
      expect(tree.first["children"].map { |c| c["name"] }).to eq([ "Demora", "Conduta de profissional", "Acolhimento" ])
      expect(tree.first["children"].first.keys).to contain_exactly("id", "name", "active")

      json_post "/ombudsman/subjects", name: "Novo"
      expect(response).to have_http_status(:forbidden)

      sign_in_as(ouvidor)
      json_post "/ombudsman/subjects", name: " Ouvidoria interna "
      expect(response).to have_http_status(:created)
      parent_id = json_body["id"]
      expect(json_body).to include("name" => "Ouvidoria interna", "active" => true, "children" => [])

      json_post "/ombudsman/subjects", name: "Prazo", parent_id: parent_id
      expect(response).to have_http_status(:created)
      child_id = json_body["id"]
      expect(json_body).not_to have_key("children")

      json_post "/ombudsman/subjects", name: "Neto", parent_id: child_id
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "too_deep", "path" => "parent_id")

      json_post "/ombudsman/subjects", name: "prazo", parent_id: parent_id
      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to eq("name_taken")
      json_post "/ombudsman/subjects", name: "Prazo", parent_id: SecureRandom.uuid
      expect(json_body).to include("error" => "invalid_request", "path" => "parent_id")
      json_post "/ombudsman/subjects", name: "x"
      expect(json_body["path"]).to eq("name")

      get "/ombudsman/subjects"
      mine = json_body["items"].find { |s| s["id"] == parent_id }
      expect(mine["children"].map { |c| c["name"] }).to eq([ "Prazo" ])
    end

    it "renomeia e desativa; não semeia de novo um assunto desativado" do
      sign_in_as(ouvidor)
      get "/ombudsman/subjects"
      other = json_body["items"].find { |s| s["name"] == "Outros" }
      json_patch "/ombudsman/subjects/#{other['id']}", name: "Diversos", active: false
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("name" => "Diversos", "active" => false)
      json_patch "/ombudsman/subjects/#{other['id']}", active: "sim"
      expect(json_body["path"]).to eq("active")
      json_patch "/ombudsman/subjects/#{other['id']}", name: "Acesso"
      expect(response).to have_http_status(:conflict)

      get "/ombudsman/subjects"
      expect(json_body["items"].map { |s| s["name"] }).to include("Diversos")
      expect(json_body["items"].map { |s| s["name"] }).not_to include("Outros")
      json_patch "/ombudsman/subjects/#{SecureRandom.uuid}", active: false
      expect(response).to have_http_status(:not_found)
    end

    it "administrador e respondente não leem (403)" do
      [ admin, candidate! ].each do |user|
        sign_in_as(user)
        get "/ombudsman/subjects"
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "/ombudsman/settings" do
    it "devolve os oito inteiros, pela fachada que cria a linha que falta" do
      sign_in_as(ouvidor)
      expect(Ombudsman::Settings).to receive(:ensure_defaults!).and_call_original
      get "/ombudsman/settings"
      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("response_days" => 30, "extension_days" => 30, "urgent_days" => 15, "complement_days" => 20,
                              "forwarding_days" => 20, "forwarding_extension_days" => 20, "warning_days" => 5,
                              "anonymous_daily_cap" => 50)
    end

    it "grava as chaves enviadas e deixa as outras; registra quem mudou" do
      sign_in_as(ouvidor)
      json_patch "/ombudsman/settings", response_days: 45, anonymous_daily_cap: 1000
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("response_days" => 45, "anonymous_daily_cap" => 1000, "urgent_days" => 15)
      expect(OmbudsmanSetting.find(1).updated_by_user_id).to eq(ouvidor.id)
      json_patch "/ombudsman/settings", {}
      expect(response).to have_http_status(:ok)
      expect(json_body["response_days"]).to eq(45)
    end

    it "fora da faixa, não inteiro ou chave desconhecida → 422 com path, sem gravar nada" do
      sign_in_as(ouvidor)
      json_patch "/ombudsman/settings", response_days: 121, urgent_days: 10
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "response_days")
      expect(OmbudsmanSetting.find(1).urgent_days).to eq(15)

      [ { response_days: 0 }, { warning_days: "5" }, { warning_days: 5.5 }, { extension_days: nil }, { anonymous_daily_cap: 1001 } ].each do |body|
        json_patch "/ombudsman/settings", body
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body["path"]).to eq(body.keys.first.to_s)
      end
      json_patch "/ombudsman/settings", segredo: 1
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body["path"]).to eq("segredo")
      json_patch "/ombudsman/settings", response_days: 200, extension_days: 0
      expect(json_body["problems"].map { |p| p["path"] }).to eq(%w[response_days extension_days])
    end

    it "só o ouvidor" do
      [ technician, admin, candidate! ].each do |user|
        sign_in_as(user)
        get "/ombudsman/settings"
        expect(response).to have_http_status(:forbidden)
        json_patch "/ombudsman/settings", response_days: 10
        expect(response).to have_http_status(:forbidden)
      end
      expect(OmbudsmanSetting.find(1).response_days).to eq(30)
    end
  end

  describe "/ombudsman/options (Q7)" do
    it "traz só os ativos, com has_active_responder e as unidades do profissional" do
      ubs = unit!("UBS Ativa")
      caps = unit!("CAPS Ativo", kind: "other")
      off = unit!("UBS Desligada")
      off.update!(active: false)
      covered = department!("Setor Coberto")
      uncovered = department!("Setor Descoberto")
      department!("Setor Inativo").update!(active: false)
      responder!(covered)
      responder!(ubs)
      lapsed = responder!(caps)
      lapsed.memberships.each(&:revoke!) # sem o papel, a linha não conta

      doctor = staff_with("medico-opt@cidade.gov.br", "health_professional")
      link_professional!(doctor, ubs)
      link_professional!(doctor, caps, cbo: "225142")
      closed = staff_with("ex-opt@cidade.gov.br", "health_professional")
      link_professional!(closed, ubs).update!(ended_at: Time.current, ended_by_user: ombudsman_admin!)
      only_inactive_unit = staff_with("so-off@cidade.gov.br", "health_professional")
      link_professional!(only_inactive_unit, off)

      parent = OmbudsmanSubject.where(parent_id: nil).find_by!(name: "Acesso")
      parent.children.find_by!(name: "Fila").update!(active: false)
      OmbudsmanSubject.where(parent_id: nil).find_by!(name: "Outros").update!(active: false)

      sign_in_as(technician)
      get "/ombudsman/options"
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to contain_exactly("subjects", "health_units", "departments", "professionals")

      access = json_body["subjects"].find { |s| s["name"] == "Acesso" }
      expect(access["children"].map { |c| c["name"] }).to eq([ "Agendamento", "Falta de profissional" ])
      expect(access.keys).to contain_exactly("id", "name", "children")
      expect(json_body["subjects"].map { |s| s["name"] }).not_to include("Outros")

      expect(json_body["health_units"]).to contain_exactly(
        { "id" => ubs.id, "name" => "UBS Ativa", "kind" => "ubs", "has_active_responder" => true },
        { "id" => caps.id, "name" => "CAPS Ativo", "kind" => "other", "has_active_responder" => false }
      )
      expect(json_body["departments"]).to contain_exactly(
        { "id" => covered.id, "name" => "Setor Coberto", "has_active_responder" => true },
        { "id" => uncovered.id, "name" => "Setor Descoberto", "has_active_responder" => false }
      )
      expect(json_body["professionals"]).to eq(
        [ { "id" => doctor.professional.id, "name" => doctor.professional.professional_name, "health_unit_ids" => [ caps.id, ubs.id ].sort } ]
      )
    end

    it "lê pela fachada de configuração; técnico e ouvidor leem; administrador e respondente não" do
      sign_in_as(ouvidor)
      expect(Ombudsman::Settings).to receive(:ensure_defaults!).and_call_original
      get "/ombudsman/options"
      expect(response).to have_http_status(:ok)
      expect(json_body["subjects"].size).to eq(OmbudsmanSubject::DEFAULT_TREE.size)

      [ admin, candidate! ].each do |user|
        sign_in_as(user)
        get "/ombudsman/options"
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  # Recusa uniforme da chave desconhecida: 422 com o NOME da chave no path,
  # nada gravado (como as outras rotas do módulo).
  describe "chave desconhecida" do
    it "POST /departments → 422 com o nome da chave; chave na query → 422" do
      sign_in_as(admin)
      json_post "/departments", name: "Setor Novo", parent_id: SecureRandom.uuid
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "parent_id")
      post "/departments?name=Setor", params: { name: "Setor Novo" }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "name")
      expect(Department.where(name: "Setor Novo")).to be_empty
    end

    it "PATCH /departments/:id → 422 com o nome da chave; chave na query → 422" do
      dept = department!("Setor Antigo")
      sign_in_as(admin)
      json_patch "/departments/#{dept.id}", name: "Setor Renomeado", updated_by_user_id: admin.id
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "updated_by_user_id")
      patch "/departments/#{dept.id}?active=false", params: { name: "Setor Renomeado" }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      expect(json_body).to include("error" => "invalid_request", "path" => "active")
      expect(dept.reload.name).to eq("Setor Antigo")
    end

    it "POST /ombudsman/subjects → 422 com o nome da chave" do
      sign_in_as(ouvidor)
      json_post "/ombudsman/subjects", name: "Assunto Novo", position: 1
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "position")
      expect(OmbudsmanSubject.where(name: "Assunto Novo")).to be_empty
    end

    it "PATCH /ombudsman/subjects/:id com parent_id (o pai não muda) → 422 path parent_id" do
      sign_in_as(ouvidor)
      get "/ombudsman/subjects"
      parent, other = json_body["items"].first(2)
      child = parent["children"].first
      json_patch "/ombudsman/subjects/#{child['id']}", name: "Movido", parent_id: other["id"]
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "parent_id")
      expect(OmbudsmanSubject.find(child["id"])).to have_attributes(name: child["name"], parent_id: parent["id"])
    end

    it "POST /ombudsman/responders → 422 com o nome da chave" do
      sign_in_as(ouvidor)
      json_post "/ombudsman/responders", user_id: candidate!.id, department_id: department!.id, active: false
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "active")
      expect(OmbudsmanResponder.count).to eq(0)
    end

    it "PATCH /ombudsman/responders/:id → 422 com o nome da chave" do
      sign_in_as(ouvidor)
      json_post "/ombudsman/responders", user_id: candidate!.id, department_id: department!.id
      id = json_body["id"]
      json_patch "/ombudsman/responders/#{id}", active: false, department_id: department!.id
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to include("error" => "invalid_request", "path" => "department_id")
      expect(OmbudsmanResponder.find(id).active).to be(true)
    end
  end
end
