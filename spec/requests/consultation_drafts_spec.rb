require "rails_helper"

# Rascunho de consulta órfão (card rotasaude/api#51; ADR 0031): o municipal_admin
# lista, vê candidatos, descarta ou designa outro profissional da unidade.
# Papel e step-up são do controlador; discard/reassign exigem step-up.
RSpec.describe "Rascunhos de consulta órfãos", type: :request do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(1) }
  let(:admin) { staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }
  let(:consultation) do
    started_consultation!(unit: unit, doctor: doctor, citizen: citizen).tap do |c|
      Consultations::SaveDraft.call(consultation: c, params: draft_body, by: doctor)
    end
  end
  let(:base) { "/clinical_record/consultation_drafts" }
  let(:reason) { "Profissional desligada da unidade" }

  it "anônimo → 401; profissional sem admin → 403 missing_role; interruptor desligado → 403 feature_disabled" do
    consultation
    get base
    expect(response).to have_http_status(:unauthorized)
    sign_in_as(doctor)
    get base
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    json_post "#{base}/#{consultation.id}/discard", reason: reason
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    clinical_city!(enabled: false)
    sign_in_as(admin)
    get base
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "clinical_record" } ])
  end

  it "lista sem step-up, no formato combinado, sem nome do paciente, CPF nem texto clínico" do
    consultation
    sign_in_as(admin)
    get base
    expect(response).to have_http_status(:ok)
    draft = json_body["drafts"].sole
    expect(draft.keys).to match_array(%w[consultation_id attendance_id health_unit author author_linked patient_initials issued_documents started_at last_saved_at])
    expect(draft).to include("consultation_id" => consultation.id, "attendance_id" => consultation.attendance_id,
                             "health_unit" => { "id" => unit.id, "name" => unit.name }, "author_linked" => true,
                             "patient_initials" => "M.A.S.", "issued_documents" => 0)
    expect(draft["author"].keys).to match_array(%w[user_id name])
    expect(draft["author"]["user_id"]).to eq(doctor.id)
    expect { Time.iso8601(draft["started_at"]) && Time.iso8601(draft["last_saved_at"]) }.not_to raise_error
    expect(response.body).not_to match(/Maria|Aparecida|sede|poliúria|Metformina|#{citizen.cpf.to_s.gsub(/\D/, '')}/)
  end

  it "candidatos: sem step-up; só profissionais elegíveis; 404 e 409 nos casos de borda" do
    nurse = nurse!(unit)
    dentist!(unit)
    other = doctor!(unit)
    consultation
    sign_in_as(admin)
    get "#{base}/#{consultation.id}/candidates"
    expect(response).to have_http_status(:ok)
    rows = json_body["candidates"]
    expect(rows.map { |r| r["user_id"] }).to contain_exactly(nurse.id, other.id)
    expect(rows.first.keys).to match_array(%w[user_id name cbo_code cbo_title council council_state registration_number])
    get "#{base}/#{SecureRandom.uuid}/candidates"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    get "#{base}/lixo/candidates"
    expect(response).to have_http_status(:not_found)
    ConsultationDrafts::Discard.call(consultation_id: consultation.id, reason: reason, by: admin)
    get "#{base}/#{consultation.id}/candidates"
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "not_draft" } ])
  end

  describe "discard" do
    it "sem step-up 401; motivo curto 422; sem JSON 415" do
      consultation
      sign_in_as(step_up_enrolled!(admin))
      json_post "#{base}/#{consultation.id}/discard", reason: reason
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      stepped_up!(admin)
      json_post "#{base}/#{consultation.id}/discard", reason: "curto"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_reason" } ])
      post "#{base}/#{consultation.id}/discard", params: { reason: reason }
      expect(response).to have_http_status(:unsupported_media_type)
      expect(consultation.reload).to be_draft
    end

    it "sucesso 200; o desfecho sai depois pelo close de um profissional da unidade; de novo 409; inexistente 404" do
      consultation
      stepped_up!(admin)
      json_post "#{base}/#{consultation.id}/discard", reason: reason
      expect([ response.status, json_body ]).to eq([ 200, { "consultation_id" => consultation.id, "status" => "discarded" } ])
      expect(consultation.reload.status).to eq("discarded")
      json_post "#{base}/#{consultation.id}/discard", reason: reason
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "not_draft" } ])
      json_post "#{base}/#{SecureRandom.uuid}/discard", reason: reason
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      sign_in_as(doctor!(unit))
      json_post "/attendance/attendances/#{consultation.attendance_id}/close", outcome: "discharged"
      expect(response).to have_http_status(:ok)
    end

    it "consulta finalizada → 409 not_draft; o motivo não vai a nenhum DomainEvent" do
      done = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
      stepped_up!(admin)
      json_post "#{base}/#{done.id}/discard", reason: reason
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "not_draft" } ])
      json_post "#{base}/#{consultation.id}/discard", reason: reason
      expect(response).to have_http_status(:ok)
      expect(DomainEvent.where(name: "consultation.draft_discarded")).to exist
      expect(DomainEvent.all.map { |e| e.payload.to_json }.join).not_to include(reason)
    end
  end

  describe "reassign" do
    let(:nurse) { nurse!(unit) }

    it "sem step-up 401; motivo curto 422; profissional inválido 422; mesma autora 422; consulta inexistente 404" do
      dentist = dentist!(unit)
      consultation
      sign_in_as(step_up_enrolled!(admin))
      json_post "#{base}/#{consultation.id}/reassign", user_id: nurse.id, reason: reason
      expect([ response.status, json_body ]).to eq([ 401, { "error" => "mfa_required" } ])
      stepped_up!(admin)
      json_post "#{base}/#{consultation.id}/reassign", user_id: nurse.id, reason: "curto"
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_reason" } ])
      json_post "#{base}/#{consultation.id}/reassign", user_id: dentist.id, reason: reason
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_professional" } ])
      json_post "#{base}/#{consultation.id}/reassign", user_id: doctor.id, reason: reason
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "same_author" } ])
      json_post "#{base}/#{SecureRandom.uuid}/reassign", user_id: nurse.id, reason: reason
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    end

    it "sucesso 200; o novo autor lê e edita; a antiga recebe 403 not_author; o motivo não vai a evento" do
      consultation
      other = doctor!(unit)
      stepped_up!(admin)
      json_post "#{base}/#{consultation.id}/reassign", user_id: other.id, reason: reason
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to match_array(%w[consultation_id author])
      expect(json_body["consultation_id"]).to eq(consultation.id)
      expect(json_body["author"]).to include("user_id" => other.id)
      expect(json_body["author"]["name"]).to be_present
      expect(DomainEvent.all.map { |e| e.payload.to_json }.join).not_to include(reason)

      sign_in_as(other)
      get "/attendance/consultations/#{consultation.id}"
      expect(response).to have_http_status(:ok)
      patch "/attendance/consultations/#{consultation.id}", params: { plan: "Novo plano" }.to_json,
                                                              headers: { "CONTENT_TYPE" => "application/json" }
      expect(response).to have_http_status(:ok)
      sign_in_as(doctor)
      patch "/attendance/consultations/#{consultation.id}", params: { plan: "x" }.to_json,
                                                              headers: { "CONTENT_TYPE" => "application/json" }
      expect([ response.status, json_body["error"] ]).to eq([ 403, "not_author" ])
    end

    it "consulta finalizada → 409 not_draft" do
      done = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
      stepped_up!(admin)
      json_post "#{base}/#{done.id}/reassign", user_id: nurse.id, reason: reason
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "not_draft" } ])
    end
  end
end
