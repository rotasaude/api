require "rails_helper"

# Contrato §4 e §11 L5; §12 P3. Cidadão nunca vê sugestão; aqui, só o painel da equipe.
RSpec.describe "Linhas de cuidado — sugestões", type: :request do
  before { care_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let(:tech) { screener!(unit, cbo: "322205") }
  let!(:team) { care_team!(unit, doctor, tech) }
  let(:pregnancy) { adopted_line!("pregnancy_c3") }

  def viewed = DomainEvent.where(name: "clinical_record.viewed").select { |e| e.payload["access"] == "care_line" }

  it "lista sem texto clínico, com trilha; conta sem trilha; aceita com DUM; técnico não confirma" do
    patient = care_patient!(age: 27, sex: "female", problems: [ %w[ciap2 W78] ], unit: unit, doctor: doctor)
    suggestion = CareLineSuggestion.create!(care_line: pregnancy, team: team, patient: patient, reason: "problem",
                                            evidence_ref: "patient_problem:#{patient.problems.sole.id}")
    sign_in_as(tech)
    get "/care_lines/suggestions", params: { team_id: team.id }
    item = json_body["suggestions"].sole
    expect(item.keys).to match_array(%w[id person care_line reason created_at enrollment_id team_id])
    expect(item["reason"]).to eq("problem")
    expect(item["team_id"]).to eq(team.id)
    expect(item["care_line"]).to eq("id" => pregnancy.id, "name" => pregnancy.name, "requires_anchor" => "lmp")
    expect(item.to_json).not_to include("W78")
    expect(json_body["next_before"]).to be_nil
    expect(viewed.map { |e| e.payload.values_at("user_id", "patient_id", "care_line_suggestion_id") }).to eq([ [ tech.id, patient.id, suggestion.id ] ])
    get "/care_lines/suggestions/count", params: { team_id: team.id }
    expect(json_body).to eq("count" => 1)
    expect(viewed.size).to eq(1)
    json_post "/care_lines/suggestions/#{suggestion.id}/accept", team_id: team.id, anchor_date: (Time.zone.today - 70).iso8601
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "cbo_not_allowed")
    sign_in_as(doctor)
    json_post "/care_lines/suggestions/#{suggestion.id}/accept", team_id: team.id
    expect(json_body).to eq("error" => "anchor_required")
    json_post "/care_lines/suggestions/#{suggestion.id}/accept", team_id: team.id, anchor_date: (Time.zone.today - 70).iso8601
    expect(response).to have_http_status(:created)
    expect(json_body).to include("anchor_date" => (Time.zone.today - 70).iso8601, "status" => "active")
    expect(json_body["care_line"]).to include("requires_anchor" => "lmp")
  end

  it "recusa com motivo; sugestão de outra equipe por id → 404" do
    other_unit = care_unit!
    other_team = care_team!(other_unit, care_doctor!(other_unit))
    mine = CareLineSuggestion.create!(care_line: pregnancy, team: team, citizen: care_citizen!(age: 25, sex: "female"), reason: "declared")
    theirs = CareLineSuggestion.create!(care_line: pregnancy, team: other_team, citizen: care_citizen!(age: 26, sex: "female"), reason: "declared")
    sign_in_as(doctor)
    json_post "/care_lines/suggestions/#{theirs.id}/dismiss", reason: "Não é da área"
    expect(response).to have_http_status(:not_found)
    json_post "/care_lines/suggestions/#{theirs.id}/accept", team_id: team.id, anchor_date: (Time.zone.today - 70).iso8601
    expect(response).to have_http_status(:not_found)
    expect(theirs.reload.status).to eq("pending")
    json_post "/care_lines/suggestions/#{mine.id}/dismiss", reason: ""
    expect(json_body).to eq("error" => "reason_required", "field" => "reason")
    json_post "/care_lines/suggestions/#{mine.id}/dismiss", reason: "Gestação já acompanhada no convênio"
    expect(json_body).to eq("id" => mine.id, "status" => "dismissed")
    get "/care_lines/suggestions", params: { team_id: other_team.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "out_of_scope")
    get "/care_lines/suggestions/count", params: { team_id: other_team.id }
    expect(json_body).to eq("error" => "out_of_scope")
  end

  it "aceitar a própria sugestão para equipe alheia → 403 out_of_scope, sem gravar nada" do
    other_unit = care_unit!
    other_team = care_team!(other_unit, care_doctor!(other_unit))
    citizen = care_citizen!(age: 25, sex: "female")
    mine = CareLineSuggestion.create!(care_line: pregnancy, team: team, citizen: citizen, reason: "declared")
    sign_in_as(doctor)
    expect { json_post "/care_lines/suggestions/#{mine.id}/accept", team_id: other_team.id, anchor_date: (Time.zone.today - 70).iso8601 }
      .not_to change(Patient, :count)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "out_of_scope")
    expect(mine.reload.status).to eq("pending")
  end

  it "encerramento: aceitar `{}` encerra com discharge (200); o de outra equipe → 404" do
    other_unit = care_unit!
    other_doctor = care_doctor!(other_unit)
    other_team = care_team!(other_unit, other_doctor)
    elderly = adopted_line!("elderly_c6")
    enrollment = care_enrollment!(patient: care_patient!(age: 70, sex: "male"), line: elderly, team: team, by: doctor)
    foreign = care_enrollment!(patient: care_patient!(age: 71, sex: "male"), line: elderly, team: other_team, by: other_doctor)
    closure = CareLineSuggestion.create!(care_line: elderly, team: team, patient: enrollment.patient, reason: "resolved_problem", enrollment: enrollment)
    theirs = CareLineSuggestion.create!(care_line: elderly, team: other_team, patient: foreign.patient, reason: "resolved_problem", enrollment: foreign)
    sign_in_as(tech)
    json_post "/care_lines/suggestions/#{theirs.id}/accept", {}
    expect(response).to have_http_status(:not_found)
    expect(foreign.reload.status).to eq("active")
    expect(theirs.reload.status).to eq("pending")
    json_post "/care_lines/suggestions/#{closure.id}/accept", {}
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => enrollment.id, "status" => "ended", "ended_reason" => "discharge")
    expect(closure.reload.status).to eq("accepted")
  end

  it "filtro de linha mal formado → 422; cursor inválido → 422; pagina com next_before" do
    3.times { |i| CareLineSuggestion.create!(care_line: pregnancy, team: team, citizen: care_citizen!(age: 25 + i, sex: "female"), reason: "declared") }
    sign_in_as(doctor)
    get "/care_lines/suggestions", params: { team_id: team.id, care_line_id: "x" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_filter" } ])
    get "/care_lines/suggestions", params: { team_id: team.id, before: "x" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cursor" } ])
    get "/care_lines/suggestions", params: { team_id: team.id, care_line_id: pregnancy.id, limit: 2 }
    first = json_body["suggestions"].map { |s| s["id"] }
    expect(first.size).to eq(2)
    get "/care_lines/suggestions", params: { team_id: team.id, care_line_id: pregnancy.id, limit: 2, before: json_body["next_before"] }
    expect(json_body["next_before"]).to be_nil
    expect(first + json_body["suggestions"].map { |s| s["id"] }).to match_array(CareLineSuggestion.pluck(:id))
  end
end
