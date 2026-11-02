require "rails_helper"

# Módulo 29, Task 8 (ADR 0047; contrato §2, §5; §15 V5, V6, V10): registro da
# dose na sala e a leitura nominal da dose.
RSpec.describe "Sala de vacina — dose aplicada", type: :request do
  let!(:city) { vaccination_city! }
  let(:room) { vaccine_room! }
  let(:vaccinator) { room_member!(room) }
  let(:lead) { room_member!(room, role: "room_lead", cbo: "223505") }
  let(:child) { vaccine_patient!(birth_date: Date.current - 61, sex: "female") }
  let(:lot) { vaccine_lot!(room, code: "42", doses: 5) }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:base) { "/vaccination/rooms/#{room.id}/immunizations" }

  def dose_body(**over)
    { patient_id: child.id, immunobiological_code: "42", dose_code: "1", strategy: "1", care_group: "121", route: "3", site: "18",
      maternal_condition: "1", applied_at: Time.current.iso8601, lot_id: lot.id }.merge(over)
  end

  def post_dose(**over) = post(base, params: dose_body(**over).to_json, headers: json_headers)
  def trails = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at, :id).map(&:payload)

  describe "POST /vaccination/rooms/:room_id/immunizations" do
    before { sign_in_as(vaccinator) }

    it "201 com a forma <immunization>, can_cancel do autor e rnds.status not_sent (envio desligado)" do
      post_dose
      expect(response).to have_http_status(:created)
      expect(json_body).to include("immunobiological" => { "code" => "42", "name" => "Vacina penta (DTP/HB/Hib)" }, "transcription" => false,
                                   "status" => "active", "can_cancel" => true, "strategy" => "1", "care_group" => "121", "route" => "3",
                                   "site" => "18", "maternal_condition" => "1", "replaces_id" => nil, "campaign_id" => nil)
      expect(json_body["lot"]).to include("id" => lot.id, "number" => lot.lot_number)
      expect(json_body["by"]).to eq("name" => vaccinator.professional.professional_name, "cbo" => "322205")
      expect(json_body["rnds"]).to eq("status" => "not_sent", "sent_at" => nil, "accepted_at" => nil, "block_reason" => nil, "error" => nil)
      expect(json_body).not_to have_key("override_reason")
      expect(Immunization.find(json_body["id"])).to have_attributes(patient_id: child.id, vaccine_room_id: room.id)
    end

    it "com o envio ligado, a entrada pendente aparece como pending" do
      rnds_credential!
      %w[rnds_immunization rnds_mock].each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: ledi_maintainer!) }
      post_dose
      expect(json_body.dig("rnds", "status")).to eq("pending")
    end

    it "recusas: 422 com problems[]; avisos com overridable: true; com override_reason grava e não devolve o motivo" do
      post_dose(route: "99", lot_id: SecureRandom.uuid)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_value", "path" => "route",
                              "problems" => [ { "path" => "route", "error" => "invalid_value" }, { "path" => "lot_id", "error" => "lot_not_in_room" } ])
      post_dose
      post_dose(dose_code: "2")
      expect(json_body["problems"]).to eq([ { "path" => "dose_code", "error" => "interval_too_short", "overridable" => true } ])
      post_dose(dose_code: "2", override_reason: "Viagem da família para fora do país")
      expect(response).to have_http_status(:created)
      expect(response.body).not_to include("Viagem")
    end

    it "fora da equipe 403; patient_id inexistente 404; ausente 422; dado do paciente na query 422" do
      sign_in_as(room_member!(vaccine_room!))
      post_dose
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      sign_in_as(vaccinator)
      post_dose(patient_id: SecureRandom.uuid)
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      post(base, params: dose_body.except(:patient_id).to_json, headers: json_headers)
      expect([ response.status, json_body["path"] ]).to eq([ 422, "patient_id" ])
      post("#{base}?lot_id=#{lot.id}", params: dose_body.to_json, headers: json_headers)
      expect([ response.status, json_body["path"] ]).to eq([ 422, "lot_id" ])
      expect(Immunization.count).to eq(0)
    end

    it "nada da vacina no log" do
      log = capture_log { post_dose }
      expect(response).to have_http_status(:created)
      expect(log).not_to include(lot.lot_number)
      expect(log).not_to include('"42"')
      expect(log).not_to include("Vacina penta")
    end

    it "interruptor desligado → 403 feature_disabled" do
      Platform::Features.set!(city: city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
      post_dose
      expect([ response.status, json_body["error"], json_body["feature"] ]).to eq([ 403, "feature_disabled", "vaccination" ])
    end
  end

  describe "GET /vaccination/immunizations/:id (§15 V10)" do
    let(:dose) { record!(room, child, lot: lot, by: vaccinator) }

    def show(id = dose.id) = get("/vaccination/immunizations/#{id}")

    it "equipe da sala lê a dose com trilha; can_cancel: autor e room_lead sim, outro vacinador não" do
      dose
      before = trails.size
      sign_in_as(lead)
      show
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => dose.id, "can_cancel" => true, "status" => "active")
      expect(trails.drop(before)).to eq([ { "patient_id" => child.id, "user_id" => lead.id, "access" => "vaccination", "reason_code" => nil,
                               "person_ref" => "patient:#{child.id}" } ])
      sign_in_as(room_member!(room))
      show
      expect(json_body["can_cancel"]).to be(false)
      sign_in_as(vaccinator)
      show
      expect(json_body["can_cancel"]).to be(true)
    end

    it "dose cancelada: can_cancel falso até para o autor" do
      dose.update!(cancelled_at: Time.current, cancelled_by_user: lead, cancel_reason: "registro duplicado")
      sign_in_as(vaccinator)
      show
      expect(json_body).to include("status" => "cancelled", "can_cancel" => false)
    end

    it "fora do escopo → 404 sem trilha; inexistente ou malformado → 404" do
      dose
      before = trails.size
      sign_in_as(room_member!(vaccine_room!))
      show
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
      show(SecureRandom.uuid)
      expect(response).to have_http_status(:not_found)
      show("lixo")
      expect(response).to have_http_status(:not_found)
      expect(trails.size).to eq(before)
    end

    it "quem lê a linha do tempo do paciente (abertura justificada, patient_timeline ligado) também lê" do
      dose
      doctor = doctor!(create_unit("UBS Centro"))
      now = Time.current
      ClinicalRecordOpening.create!(patient: child, user: doctor, reason_code: "case_review", created_at: now, expires_at: now + 30.minutes)
      sign_in_as(doctor)
      show
      expect(response).to have_http_status(:not_found) # patient_timeline desligado
      Platform::Features.set!(city: city, key: "patient_timeline", enabled: true, maintainer: ledi_maintainer!)
      before = trails.size
      show
      expect(response).to have_http_status(:ok)
      expect(json_body["can_cancel"]).to be(false)
      expect(trails.drop(before)).to eq([ { "patient_id" => child.id, "user_id" => doctor.id, "access" => "vaccination",
                                            "reason_code" => "case_review", "person_ref" => "patient:#{child.id}" } ])
    end
  end

  describe "POST /vaccination/immunizations/:id/cancel (Task 9; §15 V6)" do
    let(:dose) { record!(room, child, lot: lot, by: vaccinator) }
    let(:reason) { "Dose registrada como D1 por engano" }

    def cancel_dose(id: dose.id, **body) = post("/vaccination/immunizations/#{id}/cancel", params: body.to_json, headers: json_headers)
    def replacement(**over) = dose_body(dose_code: "2", override_reason: "Correção da dose registrada antes").except(:patient_id).merge(over)

    it "step-up: sem MFA recente → 401 mfa_required, nada muda" do
      sign_in_as(lead)
      cancel_dose(reason: reason)
      expect(response).to have_http_status(:unauthorized)
      expect(json_body).to eq("error" => "mfa_required")
      expect(dose.reload.cancelled_at).to be_nil
    end

    it "200 { cancelled, replacement } com a forma <immunization>; trilha uma vez" do
      stepped_up!(lead)
      dose
      before = trails.size
      cancel_dose(reason: reason, replacement: replacement)
      expect(response).to have_http_status(:ok)
      replaced = Immunization.find_by!(replaces_id: dose.id)
      expect(json_body["cancelled"]).to include("id" => dose.id, "status" => "cancelled", "cancel_reason" => reason, "replaced_by_id" => replaced.id,
                                                "can_cancel" => false)
      expect(json_body["replacement"]).to include("id" => replaced.id, "replaces_id" => dose.id, "status" => "active", "can_cancel" => true)
      expect(json_body["replacement"]).not_to have_key("override_reason")
      expect(trails.size - before).to eq(1)
    end

    it "sem substituição → replacement null; já cancelada → 409 already_cancelled" do
      stepped_up!(vaccinator)
      cancel_dose(reason: reason)
      expect(json_body["replacement"]).to be_nil
      cancel_dose(reason: reason)
      expect(response).to have_http_status(:conflict)
      expect(json_body).to eq("error" => "already_cancelled")
    end

    it "422: motivo inválido; substituição recusada com path replacement.<campo>, nada cancelado" do
      stepped_up!(lead)
      cancel_dose(reason: "curto")
      expect(json_body).to eq("error" => "invalid_reason", "path" => "reason", "problems" => [ { "path" => "reason", "error" => "invalid_reason" } ])
      cancel_dose(reason: reason, replacement: replacement(route: "99"))
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_value", "path" => "replacement.route",
                              "problems" => [ { "path" => "replacement.route", "error" => "invalid_value" } ])
      expect(dose.reload.cancelled_at).to be_nil
    end

    it "outro vacinador da sala → 403 cancel_not_allowed; fora da sala → 404; id malformado → 404; motivo na query → 422" do
      stepped_up!(room_member!(room))
      cancel_dose(reason: reason)
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "cancel_not_allowed")
      stepped_up!(room_member!(vaccine_room!))
      cancel_dose(reason: reason)
      expect(response).to have_http_status(:not_found)
      cancel_dose(id: "x", reason: reason)
      expect(response).to have_http_status(:not_found)
      stepped_up!(lead)
      post("/vaccination/immunizations/#{dose.id}/cancel?reason=Paciente+errado+na+busca", params: "{}", headers: json_headers)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(dose.reload.cancelled_at).to be_nil
    end
  end
end
