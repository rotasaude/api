require "rails_helper"

# Contrato §5; plano, Desvios 9–10. Review Focus 3.
RSpec.describe "Linhas de cuidado — painel e busca ativa", type: :request do
  before { care_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let(:nurse) { care_nurse!(unit) }
  let!(:team) { care_team!(unit, doctor, nurse) }
  let(:elderly) { adopted_line!("elderly_c6") }

  # Em dia: consulta finalizada hoje (consulta + peso/altura). Vencida: nunca consultou.
  def enrolled!(ok:, at:)
    patient = ok ? care_patient!(age: 70, sex: "female", problems: [ %w[ciap2 K86] ], unit: unit, doctor: doctor) : care_patient!(age: 71, sex: "male")
    care_enrollment!(patient: patient, line: elderly, team: team, by: doctor, enrolled_at: at)
  end

  def viewed = DomainEvent.where(name: "clinical_record.viewed").select { |e| e.payload["access"] == "care_line" }

  it "lista nominal com situação por prática, último contato e trilha por pessoa; contadores sem trilha" do
    late = enrolled!(ok: false, at: 2.days.ago)
    fine = enrolled!(ok: true, at: 1.day.ago)
    CareLines::RecordContact.call(enrollment: late, channel: "phone", outcome: "no_answer", note: "Caixa postal", by: nurse)
    sign_in_as(nurse)
    get "/care_lines/enrollments", params: { team_id: team.id }
    expect(json_body["enrollments"].map { |e| [ e["id"], e["worst_status"] ] }).to eq([ [ fine.id, "ok" ], [ late.id, "overdue" ] ])
    row = json_body["enrollments"].last
    expect(row["person"].keys).to match_array(%w[patient_id citizen_id display_name age])
    expect(row["team"]).to eq("id" => team.id, "ine" => team.ine, "name" => team.name)
    expect(row["care_line"]).to eq("id" => elderly.id, "name" => elderly.name, "requires_anchor" => nil)
    expect(row).to include("ended_reason" => nil, "ended_at" => nil)
    expect(row["practices"].map { |p| [ p["key"], p["status"] ] }).to eq([ %w[c6_a overdue], %w[c6_b overdue], %w[c6_c untracked], %w[c6_d untracked] ])
    expect(row["last_contact"]).to include("channel" => "phone", "outcome" => "no_answer")
    expect(row["last_contact"]).not_to have_key("note")
    expect(viewed.size).to eq(2)
    expect(viewed.last.payload).to include("user_id" => nurse.id, "access" => "care_line")
    expect(viewed.last.payload.keys).to include("care_line_enrollment_id", "patient_id", "person_ref")
    get "/care_lines/enrollments/overdue/count", params: { team_id: team.id }
    expect(json_body).to eq("count" => 1)
    expect(viewed.size).to eq(2)
  end

  it "busca ativa varre em blocos: página curta com next_before até achar o vencido" do
    late = enrolled!(ok: false, at: 30.days.ago)
    10.times { |i| enrolled!(ok: true, at: (20 - i).days.ago) }
    sign_in_as(nurse)
    get "/care_lines/enrollments", params: { team_id: team.id, status: "overdue", limit: 2 }
    expect(json_body["enrollments"]).to eq([])
    expect(json_body["next_before"]).to be_present
    expect(viewed).to be_empty
    get "/care_lines/enrollments", params: { team_id: team.id, status: "overdue", limit: 2, before: json_body["next_before"] }
    expect(json_body["enrollments"].map { |e| e["id"] }).to eq([ late.id ])
    expect(json_body["next_before"]).to be_nil
    expect(viewed.map { |e| e.payload["care_line_enrollment_id"] }).to eq([ late.id ])
  end

  it "escopo: equipe de outra unidade → 403; inscrição dela por id → 404; filtro inválido → 422" do
    other_unit = care_unit!
    other_team = care_team!(other_unit, care_doctor!(other_unit))
    foreign = care_enrollment!(patient: care_patient!(age: 70, sex: "male"), line: elderly, team: other_team, by: doctor)
    sign_in_as(nurse)
    get "/care_lines/enrollments", params: { team_id: other_team.id }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "out_of_scope")
    get "/care_lines/enrollments/overdue/count", params: { team_id: other_team.id }
    expect(json_body).to eq("error" => "out_of_scope")
    get "/care_lines/enrollments/#{foreign.id}"
    expect(response).to have_http_status(:not_found)
    json_post "/care_lines/enrollments/#{foreign.id}/contacts", channel: "phone", outcome: "reached"
    expect(response).to have_http_status(:not_found)
    json_post "/care_lines/enrollments/#{foreign.id}/end", reason: "moved"
    expect(response).to have_http_status(:not_found)
    expect(foreign.reload.status).to eq("active")
    expect(CareOutreachContact.where(enrollment_id: foreign.id)).to be_empty
    get "/care_lines/enrollments", params: { team_id: team.id, status: "late" }
    expect(json_body).to eq("error" => "invalid_filter")
    get "/care_lines/enrollments", params: { team_id: team.id, care_line_id: "x" }
    expect(json_body).to eq("error" => "invalid_filter")
    get "/care_lines/enrollments", params: { team_id: team.id, before: "x" }
    expect(json_body).to eq("error" => "invalid_cursor")
    expect(viewed).to be_empty
  end

  it "inscrição manual por citizen_id (par validado) e por patient_id; ver, contatar e encerrar" do
    citizen = care_citizen!(age: 72, sex: "female")
    sign_in_as(doctor)
    json_post "/care_lines/enrollments", citizen_id: citizen.id, care_line_id: elderly.id, team_id: team.id
    expect(response).to have_http_status(:created)
    id = json_body["id"]
    expect(json_body["person"]["patient_id"]).to eq(citizen.reload.patient_id)
    # Trilha (revisão final): uma por pessoa mostrada — create, detalhe e end mostram; recusa e contato não.
    expect(viewed.map { |e| e.payload["care_line_enrollment_id"] }).to eq([ id ])
    json_post "/care_lines/enrollments", patient_id: citizen.patient_id, care_line_id: elderly.id, team_id: team.id
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "already_enrolled")
    json_post "/care_lines/enrollments/#{id}/contacts", channel: "home_visit", outcome: "reached", note: "Agendou consulta"
    expect(response).to have_http_status(:created)
    expect(viewed.size).to eq(1)
    get "/care_lines/enrollments/#{id}"
    expect(json_body["contacts"].map { |c| [ c["channel"], c["note"] ] }).to eq([ [ "home_visit", "Agendou consulta" ] ])
    expect(json_body["last_contact"]).not_to have_key("note")
    expect(viewed.size).to eq(2)
    json_post "/care_lines/enrollments/#{id}/end", reason: "moved", note: "Mudou de cidade"
    expect(json_body).to include("status" => "ended", "ended_reason" => "moved")
    expect(json_body["ended_at"]).to be_present
    expect(CareLineEnrollment.find(id).ended_note).to eq("Mudou de cidade")
    expect(viewed.size).to eq(3)
    expect(viewed.map { |e| e.payload.values_at("user_id", "care_line_enrollment_id") }.uniq).to eq([ [ doctor.id, id ] ])
    declared = verified_citizen!(exam_seq!).tap { |c| c.update_columns(verification_level: "declared") }
    json_post "/care_lines/enrollments", citizen_id: declared.id, care_line_id: elderly.id, team_id: team.id
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "citizen_not_verified")
    json_post "/care_lines/enrollments", care_line_id: elderly.id, team_id: team.id
    expect(json_body).to eq("error" => "invalid_person")
  end

  it "criação: equipe alheia → 403 out_of_scope; quem não confirma → 403 cbo_not_allowed sem criar paciente" do
    other_unit = care_unit!
    other_team = care_team!(other_unit, care_doctor!(other_unit))
    tech = screener!(unit, cbo: "322205")
    citizen = care_citizen!(age: 72, sex: "female")
    sign_in_as(doctor)
    json_post "/care_lines/enrollments", citizen_id: citizen.id, care_line_id: elderly.id, team_id: other_team.id
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "out_of_scope")
    sign_in_as(tech)
    expect { json_post "/care_lines/enrollments", citizen_id: citizen.id, care_line_id: elderly.id, team_id: team.id }
      .not_to change(Patient, :count)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "cbo_not_allowed")
    expect(citizen.reload.patient_id).to be_nil
    expect(CareLineEnrollment.count).to eq(0)
  end

  it "inscrição manual por citizen_id: DUM ausente/inválida ou linha inativa recusa sem criar paciente, vínculo nem evento" do
    pregnancy = adopted_line!("pregnancy_c3")
    citizen = care_citizen!(age: 27, sex: "female")
    sign_in_as(doctor)
    attempts = [ [ nil, 422, "anchor_required" ], [ (Time.zone.today + 1).iso8601, 422, "invalid_anchor" ], [ "ontem", 422, "invalid_anchor" ] ]
    attempts.each do |dum, status, error|
      expect { json_post "/care_lines/enrollments", { citizen_id: citizen.id, care_line_id: pregnancy.id, team_id: team.id, anchor_date: dum }.compact }
        .not_to change(Patient, :count)
      expect([ response.status, json_body ]).to eq([ status, { "error" => error } ])
    end
    pregnancy.update!(active: false)
    expect { json_post "/care_lines/enrollments", citizen_id: citizen.id, care_line_id: pregnancy.id, team_id: team.id, anchor_date: Time.zone.today.iso8601 }
      .not_to change(Patient, :count)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "line_inactive" } ])
    expect(citizen.reload.patient_id).to be_nil
    expect(DomainEvent.where(name: %w[patient.created patient.linked])).to be_empty
    expect(CareLineEnrollment.count).to eq(0)
  end

  # Revisão final, Minor 3: a recusa barata vem antes do Patients::Resolve,
  # como no aceite (known_patient_of): o 409 não liga o par.
  it "inscrição manual de par sem paciente cujo CPF já tem paciente inscrito: 409 sem ligar o par nem publicar patient.linked" do
    patient = care_patient!(age: 72, sex: "female")
    care_enrollment!(patient: patient, line: elderly, team: team, by: doctor)
    twin = care_citizen!(age: 72, sex: "female")
    twin.update!(cpf: patient.cpf)
    sign_in_as(doctor)
    expect { json_post "/care_lines/enrollments", citizen_id: twin.id, care_line_id: elderly.id, team_id: team.id }
      .not_to change { DomainEvent.where(name: %w[patient.created patient.linked]).count }
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_enrolled" } ])
    expect(twin.reload.patient_id).to be_nil
    expect(viewed).to be_empty
  end

  # P20 (coordenadora): DUM, nota e motivo só do corpo JSON, nunca da query
  # string (o padrão do declared_conditions_controller). Na query é o mesmo
  # que ausente.
  describe "dado de saúde e texto livre só do corpo JSON" do
    let(:pregnancy) { adopted_line!("pregnancy_c3") }

    def post_with_query(path, query, body) = post("#{path}?#{query.to_query}", params: body.to_json, headers: { "CONTENT_TYPE" => "application/json" })

    it "DUM na query na inscrição manual: anchor_required, sem paciente nem inscrição; no corpo, inscreve" do
      citizen = care_citizen!(age: 27, sex: "female")
      dum = (Time.zone.today - 70).iso8601
      sign_in_as(doctor)
      expect { post_with_query("/care_lines/enrollments", { anchor_date: dum }, { citizen_id: citizen.id, care_line_id: pregnancy.id, team_id: team.id }) }
        .not_to change(Patient, :count)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "anchor_required" } ])
      expect(CareLineEnrollment.count).to eq(0)
      json_post "/care_lines/enrollments", citizen_id: citizen.id, care_line_id: pregnancy.id, team_id: team.id, anchor_date: dum
      expect(response).to have_http_status(:created)
      expect(json_body["anchor_date"]).to eq(dum)
    end

    it "motivo e nota de saída na query: invalid_reason sem encerrar; nota só na query não grava" do
      enrollment = enrolled!(ok: false, at: 1.day.ago)
      sign_in_as(doctor)
      post_with_query("/care_lines/enrollments/#{enrollment.id}/end", { reason: "moved", note: "Mudou de cidade" }, {})
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_reason" } ])
      expect(enrollment.reload.status).to eq("active")
      post_with_query("/care_lines/enrollments/#{enrollment.id}/end", { note: "Mudou de cidade" }, { reason: "moved" })
      expect(response).to have_http_status(:ok)
      expect(enrollment.reload).to have_attributes(status: "ended", ended_reason: "moved", ended_note: nil)
    end

    it "nota de contato na query: o contato grava sem nota; no corpo, com nota" do
      enrollment = enrolled!(ok: false, at: 1.day.ago)
      sign_in_as(nurse)
      post_with_query("/care_lines/enrollments/#{enrollment.id}/contacts", { note: "Caixa postal" }, { channel: "phone", outcome: "no_answer" })
      expect(response).to have_http_status(:created)
      expect(CareOutreachContact.sole.note).to be_nil
      json_post "/care_lines/enrollments/#{enrollment.id}/contacts", channel: "phone", outcome: "no_answer", note: "Caixa postal"
      expect(CareOutreachContact.order(:recorded_at, :id).last.note).to eq("Caixa postal")
    end
  end

  it "escrita por cookie exige Content-Type JSON" do
    enrollment = enrolled!(ok: false, at: 1.day.ago)
    sign_in_as(nurse)
    post "/care_lines/enrollments/#{enrollment.id}/contacts", params: { channel: "phone", outcome: "reached" }
    expect(response).to have_http_status(:unsupported_media_type)
    expect(CareOutreachContact.count).to eq(0)
  end
end
