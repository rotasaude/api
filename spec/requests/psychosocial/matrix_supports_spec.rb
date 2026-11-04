require "rails_helper"

# Módulo 31 (contrato §7, P4, P12, P13, P23, P25): matriciamento do CAPS com
# uma equipe da atenção básica — gera uma ação BPA-C sem participante paciente
# pela via de toda ação (RecordAction, origin matrix_support), na mesma
# transação —, o caso compartilhado, a lista sem texto e o detalhe com os
# casos e a trilha por paciente. Relógio fixo no meio de novembro.
RSpec.describe "CAPS — matriciamento", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps) }
  let(:colleague) { caps_staff!(caps, cbo: "225133") }
  let(:ubs) { HealthUnit.create!(name: "UBS Boa Vista", kind: "ubs") }
  let(:team) { HealthTeam.create!(health_unit: ubs, ine: "0000123456", kind: "70", name: "eSF Boa Vista") }
  let(:topic) { "Manejo de crise em usuários de álcool" }
  def viewed = DomainEvent.where(name: "clinical_record.viewed")
  def recorded = DomainEvent.where(name: "psychosocial.matrix_support_recorded")

  def body(**over)
    { health_unit_id: caps.id, health_team_id: team.id, held_on: "2026-11-18", topic: topic,
      participants_user_ids: [ staff.id, colleague.id ], sigtap_code: "0301080305" }.merge(over)
  end

  # Grava pela rota, com a sessão de `by` (a equipe lotada).
  def record!(by: staff, **over)
    sign_in_as(by)
    json_post "/psychosocial/matrix_supports", body(**over)
    expect(response).to have_http_status(:created)
    PsychosocialMatrixSupport.find(json_body["id"])
  end

  describe "POST /psychosocial/matrix_supports" do
    it "grava o matriciamento e uma ação BPA-C sem participantes, na mesma transação; o evento leva só o id" do
      sign_in_as(staff)
      expect { json_post "/psychosocial/matrix_supports", body }
        .to change(PsychosocialMatrixSupport, :count).by(1).and change(PsychosocialAction, :count).by(1)
      expect(response).to have_http_status(:created)

      support = PsychosocialMatrixSupport.last
      action = support.psychosocial_action
      expect(action).to have_attributes(instrument: "bpa_c", origin: "matrix_support", sigtap_code: "0301080305", quantity: 1,
                                        health_unit_id: caps.id, professional_user_id: staff.id, cbo_code: "251510",
                                        month: Date.new(2026, 11, 1))
      expect(action.performed_at.in_time_zone.to_date).to eq(Date.new(2026, 11, 18))
      expect(action.psychosocial_action_participants).to be_empty
      expect(support).to have_attributes(health_team_id: team.id, held_on: Date.new(2026, 11, 18), topic: topic,
                                         participant_user_ids: [ staff.id, colleague.id ], recorded_by_user_id: staff.id)
      expect(recorded.last.payload).to eq("matrix_support_id" => support.id)
      expect(json_body).to include("id" => support.id, "topic" => topic, "cases" => [], "cases_count" => 0, "action_id" => action.id,
                                   "held_on" => "2026-11-18")
      expect(json_body["sigtap"]).to include("code" => "0301080305", "instrument" => "bpa_c")
      expect(json_body["health_team"]).to include("id" => team.id, "name" => "eSF Boa Vista")
      expect(json_body["participants"].map { |p| [ p["user_id"], p["cbo_code"] ] }).to eq([ [ staff.id, "251510" ], [ colleague.id, "225133" ] ])
      expect(viewed.count).to eq(0)
    end

    it "recusas de campo de uma vez: equipe de unidade CAPS, participante não lotado, data futura; nada gravado" do
      caps_team = HealthTeam.create!(health_unit: caps, ine: "0000654321", kind: "70", name: "Equipe do CAPS")
      outsider = caps_staff!(caps!(name: "CAPS Outro"))
      sign_in_as(staff)
      expect do
        json_post "/psychosocial/matrix_supports", body(health_team_id: caps_team.id, participants_user_ids: [ staff.id, outsider.id ],
                                                        held_on: "2026-11-19")
      end.not_to change(PsychosocialAction, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["problems"]).to contain_exactly({ "error" => "invalid_request", "path" => "health_team_id" },
                                                       { "error" => "invalid_request", "path" => "participants_user_ids[1]" },
                                                       { "error" => "invalid_request", "path" => "held_on" })
      expect(PsychosocialMatrixSupport.count).to eq(0)
    end

    it "participante repetido, lista vazia ou equipe inativa → invalid_request com o path" do
      sign_in_as(staff)
      json_post "/psychosocial/matrix_supports", body(participants_user_ids: [ staff.id, staff.id ])
      expect([ json_body["error"], json_body["path"] ]).to eq([ "invalid_request", "participants_user_ids[1]" ])
      json_post "/psychosocial/matrix_supports", body(participants_user_ids: [])
      expect([ json_body["error"], json_body["path"] ]).to eq([ "invalid_request", "participants_user_ids" ])
      team.update!(active: false)
      json_post "/psychosocial/matrix_supports", body
      expect([ json_body["error"], json_body["path"] ]).to eq([ "invalid_request", "health_team_id" ])
    end

    it "tema: acima de 200 → too_long; vazio → invalid_request; 200 aceito" do
      sign_in_as(staff)
      json_post "/psychosocial/matrix_supports", body(topic: "a" * 201)
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "too_long", "topic" ])
      expect(response.body).not_to include("a" * 201)
      json_post "/psychosocial/matrix_supports", body(topic: "  ")
      expect([ json_body["error"], json_body["path"] ]).to eq([ "invalid_request", "topic" ])
      record!(topic: "a" * 200)
    end

    it "código sem instrumento 01 (só RAAS ou BPA-I) → instrument_mismatch em sigtap_code; nada gravado" do
      sign_in_as(staff)
      %w[0301080208 0301080232].each do |code|
        json_post "/psychosocial/matrix_supports", body(sigtap_code: code)
        expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "instrument_mismatch", "sigtap_code" ])
      end
      expect(PsychosocialAction.count).to eq(0)
    end

    it "a crítica da ação recusa (CBO fora da lista, mês fechado) → 422 action_rejected nos campos do matriciamento, nada gravado" do
      outsider_cbo = caps_staff!(caps, cbo: "515105")
      sign_in_as(outsider_cbo)
      expect { json_post "/psychosocial/matrix_supports", body(participants_user_ids: [ outsider_cbo.id ]) }
        .not_to change(PsychosocialAction, :count)
      expect(json_body).to eq("error" => "action_rejected", "problems" => [ { "error" => "cbo_incompatible", "path" => "sigtap_code" } ])

      PsychosocialMonthClosure.create!(health_unit: caps, month: Date.new(2026, 10, 1), closed_by_user: staff, closed_at: Time.current)
      sign_in_as(staff)
      json_post "/psychosocial/matrix_supports", body(held_on: "2026-10-20")
      expect(json_body).to eq("error" => "action_rejected", "problems" => [ { "error" => "month_closed", "path" => "held_on" } ])
      expect([ PsychosocialMatrixSupport.count, PsychosocialAction.count, recorded.count ]).to eq([ 0, 0, 0 ])
    end

    it "sem lotação no CAPS → 403 not_on_caps_team; sem papel → 403 missing_role" do
      sign_in_as(caps_staff!(caps!(name: "CAPS Outro")))
      json_post "/psychosocial/matrix_supports", body
      expect([ response.status, json_body["error"] ]).to eq([ 403, "not_on_caps_team" ])
      sign_in_as(ubs_doctor!(ubs))
      json_post "/psychosocial/matrix_supports", body
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    end
  end

  describe "casos, lista e detalhe" do
    let(:patient) { caps_patient! }
    let(:shared) { "Discutido manejo da insônia com a equipe" }

    it "o caso é gravado por quem está lotado; texto curto, longo ou paciente inexistente recusados de uma vez" do
      support = record!
      sign_in_as(colleague)
      json_post "/psychosocial/matrix_supports/#{support.id}/cases", patient_id: patient.id, shared_text: shared
      expect(response).to have_http_status(:created)
      matrix_case = PsychosocialMatrixCase.last
      expect(matrix_case).to have_attributes(psychosocial_matrix_support_id: support.id, patient_id: patient.id, shared_text: shared,
                                             created_by_user_id: colleague.id)
      expect(json_body).to include("id" => matrix_case.id, "shared_text" => shared, "patient" => include("patient_id" => patient.id))
      expect(viewed.count).to eq(0)

      json_post "/psychosocial/matrix_supports/#{support.id}/cases", patient_id: SecureRandom.uuid, shared_text: "curto"
      expect(json_body["problems"]).to contain_exactly({ "error" => "invalid_request", "path" => "patient_id" },
                                                       { "error" => "invalid_request", "path" => "shared_text" })
      expect(response.body).not_to include("curto")
      json_post "/psychosocial/matrix_supports/#{support.id}/cases", patient_id: patient.id, shared_text: "a" * 2001
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "too_long", "shared_text" ])
      json_post "/psychosocial/matrix_supports/#{support.id}/cases", patient_id: patient.id, shared_text: "a" * 2000
      expect(response).to have_http_status(:created)
    end

    it "lista sem tema nem texto e sem trilha; detalhe com os casos e trilha por paciente" do
      sign_in_as(staff)
      support = record!
      json_post "/psychosocial/matrix_supports/#{support.id}/cases", patient_id: patient.id, shared_text: shared
      json_post "/psychosocial/matrix_supports/#{support.id}/cases", patient_id: patient.id, shared_text: "#{shared}, segunda parte"

      expect { get "/psychosocial/matrix_supports", params: { health_unit_id: caps.id } }.not_to(change { viewed.count })
      expect(json_body["items"].size).to eq(1)
      item = json_body["items"].first
      expect(item).to include("id" => support.id, "cases_count" => 2, "held_on" => "2026-11-18")
      expect(item.keys).not_to include("topic", "cases")
      expect(response.body).not_to include(topic, shared, patient.display_name)

      expect { get "/psychosocial/matrix_supports/#{support.id}" }.to change { viewed.count }.by(1)
      expect(json_body["topic"]).to eq(topic)
      # Relógio parado: os dois casos têm o mesmo created_at (a ordem é created_at, id).
      expect(json_body["cases"].map { |c| c["shared_text"] }).to contain_exactly(shared, "#{shared}, segunda parte")
      expect(json_body["cases"].first["patient"]).to include("patient_id" => patient.id, "name" => patient.display_name)
      expect(viewed.last.payload).to include("patient_id" => patient.id, "user_id" => staff.id, "access" => "psychosocial",
                                             "resource" => "matrix_support")
    end

    it "outro CAPS: detalhe e caso → 404; lista → 403 not_on_caps_team" do
      support = record!
      sign_in_as(caps_staff!(caps!(name: "CAPS Outro")))
      get "/psychosocial/matrix_supports/#{support.id}"
      expect(response).to have_http_status(:not_found)
      json_post "/psychosocial/matrix_supports/#{support.id}/cases", patient_id: patient.id, shared_text: shared
      expect(response).to have_http_status(:not_found)
      expect(PsychosocialMatrixCase.count).to eq(0)
      get "/psychosocial/matrix_supports", params: { health_unit_id: caps.id }
      expect([ response.status, json_body["error"] ]).to eq([ 403, "not_on_caps_team" ])
    end
  end
end
