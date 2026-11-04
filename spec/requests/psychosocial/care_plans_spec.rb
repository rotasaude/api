require "rails_helper"

# Módulo 31 (contrato §4, P4 care_plans/due, P12, P16, P25): PTS com versões
# imutáveis (a revisão grava a versão seguinte), lista da mais nova para a mais
# antiga com trilha, e a rota `care_plans/due` das revisões vencidas (o técnico
# de referência vê as suas; a coordenação, todas). Nada vai ao cidadão.
RSpec.describe "CAPS — PTS", type: :request do
  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps) }
  let(:enrollment) { enrollment!(caps, reference: staff) }
  let(:viewed) { DomainEvent.where(name: "clinical_record.viewed") }
  let(:needs) { "Reduzir as internações, retomar vínculos familiares e estabilizar o sono." }

  def goal(**over) = { text: "Voltar a frequentar a oficina duas vezes por semana", responsible_user_id: staff.id }.merge(over)

  def body(**over)
    { needs: needs, goals: [ goal ], intensity: "intensive", review_on: (Date.current + 60).iso8601 }.merge(over)
  end

  def plan!(of: enrollment, version: 1, review_on: Date.current + 60, by: staff)
    PsychosocialCarePlan.create!(psychosocial_enrollment: of, version: version, needs: needs, goals: [], intensity: "intensive",
                                 review_on: review_on, created_by_user: by)
  end

  before { sign_in_as(staff) }

  describe "POST /psychosocial/enrollments/:id/care_plans" do
    it "grava a versão 1 e depois a 2; a 1 fica como estava; o evento leva só o id; sem trilha" do
      expect { json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans", body }.not_to(change { viewed.count })
      expect(response).to have_http_status(:created)
      first = PsychosocialCarePlan.find(json_body["id"])
      expect(json_body).to include("version" => 1, "needs" => needs, "intensity" => "intensive",
                                   "review_on" => (Date.current + 60).iso8601)
      expect(json_body["goals"]).to eq([ { "text" => goal[:text], "responsible_user_id" => staff.id, "due_on" => nil } ])
      expect(json_body["created_by"]).to eq(Psychosocial::Json.pro(staff, "251510"))
      expect(DomainEvent.where(name: "psychosocial.care_plan_saved").last.payload).to eq("care_plan_id" => first.id)

      json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans",
                body(needs: "Novas necessidades", intensity: "semi_intensive", goals: [ goal(due_on: (Date.current + 30).iso8601) ])
      expect(response).to have_http_status(:created)
      expect(json_body).to include("version" => 2, "intensity" => "semi_intensive")
      expect(json_body["goals"].first["due_on"]).to eq((Date.current + 30).iso8601)
      expect(first.reload).to have_attributes(version: 1, needs: needs, intensity: "intensive")
      expect(PsychosocialCarePlan.where(psychosocial_enrollment_id: enrollment.id).count).to eq(2)
    end

    it "a versão gravada é imutável no banco" do
      json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans", body
      saved = PsychosocialCarePlan.find(json_body["id"])
      expect { saved.update_columns(intensity: "non_intensive") }.to raise_error(ActiveRecord::StatementInvalid)
      expect { saved.delete }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "responsável fora da equipe do CAPS → path goals[i].responsible_user_id, nada gravado" do
      outsider = caps_staff!(caps!(modality: "caps_ad"))
      enrollment
      expect do
        json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans", body(goals: [ goal, goal(responsible_user_id: outsider.id) ])
      end.not_to change { [ PsychosocialCarePlan.count, DomainEvent.count ] }
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "goals[1].responsible_user_id" ])
      expect(json_body["problems"]).to eq([ { "error" => "invalid_request", "path" => "goals[1].responsible_user_id" } ])
    end

    it "revisão no passado, hoje ou além de 365 dias → path review_on" do
      [ Date.current - 1, Date.current, Date.current + 366 ].each do |date|
        json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans", body(review_on: date.iso8601)
        expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "review_on" ])
      end
      json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans", body(review_on: "amanhã")
      expect(json_body["path"]).to eq("review_on")
      json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans", body(review_on: (Date.current + 365).iso8601)
      expect(response).to have_http_status(:created)
    end

    it "limites de texto: needs até 4000 e cada objetivo até 500, com o path (P12)" do
      json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans",
                body(needs: "n" * 4001, goals: [ goal, goal(text: "g" * 501) ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["problems"]).to contain_exactly({ "error" => "too_long", "path" => "needs" },
                                                       { "error" => "too_long", "path" => "goals[1].text" })
      expect(json_body["error"]).to eq("too_long")

      json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans", body(needs: "n" * 4000, goals: [ goal(text: "g" * 500) ])
      expect(response).to have_http_status(:created)
    end

    it "campos vazios ou fora da forma, todos de uma vez" do
      json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans",
                { needs: "  ", goals: [ { text: "", responsible_user_id: "x", due_on: "ontem" }, "solto" ], intensity: "total",
                  review_on: nil, extra: 1 }
      expect(json_body["problems"].map { |p| p["path"] })
        .to contain_exactly("needs", "goals[0].text", "goals[0].responsible_user_id", "goals[0].due_on", "goals[1]", "intensity",
                            "review_on", "extra")

      json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans", body(goals: [])
      expect(json_body["path"]).to eq("goals")
      json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans", body(goals: Array.new(21) { goal })
      expect(json_body["path"]).to eq("goals")
      json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans", body(goals: Array.new(20) { goal })
      expect(response).to have_http_status(:created)
    end

    it "matrícula encerrada → 409 already_closed" do
      enrollment.update!(closed_on: Date.current, destination: "01", closed_by_user: staff)
      expect { json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans", body }.not_to change(PsychosocialCarePlan, :count)
      expect([ response.status, json_body["error"] ]).to eq([ 409, "already_closed" ])
    end

    it "matrícula de outro CAPS → 404; papel fora do CAPS → 403; query com dado → 422" do
      other = enrollment!(caps!(modality: "caps_ad"))
      json_post "/psychosocial/enrollments/#{other.id}/care_plans", body
      expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
      json_post "/psychosocial/enrollments/nao-e-uuid/care_plans", body
      expect(response).to have_http_status(:not_found)

      post "/psychosocial/enrollments/#{enrollment.id}/care_plans?needs=segredo", params: body.to_json,
                                                                                    headers: { "CONTENT_TYPE" => "application/json" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "needs" ])

      sign_in_as(ubs_doctor!(create_unit))
      json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans", body
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    end

    it "o texto do PTS não vai ao log" do
      log = capture_log { json_post "/psychosocial/enrollments/#{enrollment.id}/care_plans", body }
      expect(log).not_to include("retomar vínculos familiares")
      expect(log).not_to include("oficina duas vezes")
    end
  end

  describe "GET /psychosocial/enrollments/:id/care_plans" do
    it "devolve as versões da mais nova para a mais antiga e grava uma trilha `care_plans`" do
      plan!(version: 1, review_on: Date.current + 10)
      plan!(version: 2, review_on: Date.current + 20)
      expect { get "/psychosocial/enrollments/#{enrollment.id}/care_plans" }.to change { viewed.count }.by(1)
      expect(response).to have_http_status(:ok)
      expect(json_body["items"].map { |i| i["version"] }).to eq([ 2, 1 ])
      expect(json_body["items"].first.keys).to contain_exactly("id", "version", "needs", "goals", "intensity", "review_on",
                                                               "created_by", "created_at")
      expect(viewed.last.payload).to include("patient_id" => enrollment.patient_id, "user_id" => staff.id, "access" => "psychosocial",
                                             "resource" => "care_plans")
    end

    it "sem versão, lista vazia; outro CAPS → 404 sem trilha" do
      get "/psychosocial/enrollments/#{enrollment.id}/care_plans"
      expect(json_body).to eq("items" => [])

      other = enrollment!(caps!(modality: "caps_ad"))
      expect { get "/psychosocial/enrollments/#{other.id}/care_plans" }.not_to(change { viewed.count })
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /psychosocial/care_plans/due" do
    let(:lead) { caps_staff!(caps, lead: true, cbo: "223505") }
    let(:other_tech) { caps_staff!(caps) }

    def due_ids(user, unit = caps)
      sign_in_as(user)
      get "/psychosocial/care_plans/due", params: { health_unit_id: unit.id }
      raise "due recusada: #{response.body}" unless response.status == 200

      json_body["items"].map { |item| item["enrollment_id"] }
    end

    let!(:overdue) { enrollment!(caps, reference: staff).tap { |e| plan!(of: e, review_on: Date.current - 1) } }
    let!(:in_day) { enrollment!(caps, reference: staff).tap { |e| plan!(of: e, review_on: Date.current + 1) } }
    let!(:renewed) do
      enrollment!(caps, reference: staff).tap do |e|
        plan!(of: e, version: 1, review_on: Date.current - 5)
        plan!(of: e, version: 2, review_on: Date.current + 30)
      end
    end
    let!(:closed) do
      enrollment!(caps, reference: staff).tap do |e|
        plan!(of: e, review_on: Date.current - 3)
        e.update!(closed_on: Date.current, destination: "01", closed_by_user: staff)
      end
    end
    let!(:no_plan_old) { enrollment!(caps, reference: staff, started_on: Date.current - 100) }
    let!(:no_plan_new) { enrollment!(caps, reference: staff, started_on: Date.current - 10) }
    let!(:others) { enrollment!(caps, reference: other_tech).tap { |e| plan!(of: e, review_on: Date.current - 2, by: other_tech) } }

    it "o técnico de referência vê só as suas vencidas e as sem PTS há mais de care_plan_review_days" do
      expect(due_ids(staff)).to contain_exactly(overdue.id, no_plan_old.id)
    end

    it "a coordenação vê todas do CAPS; outro técnico, só as dele" do
      expect(due_ids(lead)).to contain_exactly(overdue.id, no_plan_old.id, others.id)
      expect(due_ids(other_tech)).to contain_exactly(others.id)
    end

    it "o item leva a matrícula, o paciente e a revisão (nula sem PTS); sem trilha" do
      sign_in_as(staff)
      expect { get "/psychosocial/care_plans/due", params: { health_unit_id: caps.id } }.not_to(change { viewed.count })
      items = json_body["items"].index_by { |i| i["enrollment_id"] }
      expect(items.fetch(overdue.id)).to eq("enrollment_id" => overdue.id, "patient" => Psychosocial::Json.patient_ref(overdue.patient),
                                            "review_on" => (Date.current - 1).iso8601)
      expect(items.fetch(no_plan_old.id)["review_on"]).to be_nil
    end

    it "o prazo vem dos parâmetros do CAPS" do
      PsychosocialSetting.current.update!(care_plan_review_days: 365)
      expect(due_ids(staff)).to contain_exactly(overdue.id)
      PsychosocialSetting.current.update!(care_plan_review_days: 30)
      no_plan_new.update!(started_on: Date.current - 31)
      expect(due_ids(staff)).to contain_exactly(overdue.id, no_plan_old.id, no_plan_new.id)
    end

    it "CAPS não lotado → 403; sem o papel → 403; unidade inválida e chave fora da lista → 422" do
      sign_in_as(staff)
      get "/psychosocial/care_plans/due", params: { health_unit_id: caps!(modality: "caps_ad").id }
      expect([ response.status, json_body["error"] ]).to eq([ 403, "not_on_caps_team" ])
      get "/psychosocial/care_plans/due", params: { health_unit_id: "x" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "health_unit_id" ])
      get "/psychosocial/care_plans/due", params: { health_unit_id: caps.id, q: "Renato" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "q" ])
      sign_in_as(ubs_doctor!(create_unit))
      get "/psychosocial/care_plans/due", params: { health_unit_id: caps.id }
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    end
  end
end
