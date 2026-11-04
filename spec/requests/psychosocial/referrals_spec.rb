require "rails_helper"

# Módulo 31 (contrato §4, P12, P25): encaminhamento da UBS ao CAPS. Escreve o
# health_professional com vínculo em unidade não CAPS, em contexto de leitura
# do prontuário do paciente; a equipe do CAPS lista sem o motivo e lê o
# detalhe com o motivo e a trilha.
RSpec.describe "CAPS — encaminhamento", type: :request do
  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:ubs) { create_unit("UBS Vila Verde") }
  let(:doctor) { ubs_doctor!(ubs) }
  let(:patient) { caps_patient! }
  let(:reason) { "Ideação persistente, sem resposta a duas tentativas terapêuticas na UBS" }
  let(:viewed) { DomainEvent.where(name: "clinical_record.viewed") }

  def in_context!(who = doctor, of: patient)
    consulting_attendance!(ubs, citizen: Citizen.find_by!(patient_id: of.id), doctor: who)
  end

  def body(**over) = { patient_id: patient.id, health_unit_id: caps.id, reason: reason, priority: "priority" }.merge(over)

  describe "POST /psychosocial/referrals" do
    it "o médico da UBS em contexto encaminha; o evento leva só o id" do
      in_context!
      sign_in_as(doctor)
      expect { json_post "/psychosocial/referrals", body }.to change(PsychosocialReferral, :count).by(1)
      expect(response).to have_http_status(:created)
      referral = PsychosocialReferral.last
      expect(json_body.except("created_at")).to eq("id" => referral.id, "health_unit_id" => caps.id, "priority" => "priority",
                                                   "status" => "pending")
      expect(Time.iso8601(json_body["created_at"])).to be_within(1.second).of(referral.created_at)
      expect(referral).to have_attributes(patient_id: patient.id, from_health_unit_id: ubs.id, referred_by_user_id: doctor.id,
                                          reason: reason, status: "pending")
      expect(DomainEvent.where(name: "psychosocial.referral_created").last.payload).to eq("referral_id" => referral.id)
    end

    it "sem contexto → 403 out_of_context, nada gravado" do
      sign_in_as(doctor)
      json_post "/psychosocial/referrals", body
      expect([ response.status, json_body["error"] ]).to eq([ 403, "out_of_context" ])
      expect(PsychosocialReferral.count).to eq(0)
    end

    it "sem health_professional ou só com vínculo no CAPS → 403 missing_role" do
      sign_in_as(caps_staff!(caps))
      json_post "/psychosocial/referrals", body
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])

      sign_in_as(doctor!(caps))
      json_post "/psychosocial/referrals", body
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    end

    it "recusas de campo de uma vez: motivo curto, CAPS de destino que não é CAPS, prioridade fora da lista" do
      in_context!
      sign_in_as(doctor)
      json_post "/psychosocial/referrals", body(reason: "curto", health_unit_id: ubs.id, priority: "urgent")
      expect(json_body["problems"]).to contain_exactly({ "error" => "invalid_request", "path" => "reason" },
                                                       { "error" => "invalid_request", "path" => "health_unit_id" },
                                                       { "error" => "invalid_request", "path" => "priority" })
      expect(response.body).not_to include("curto")
    end

    it "motivo acima de 2000 caracteres → 422 too_long" do
      in_context!
      sign_in_as(doctor)
      json_post "/psychosocial/referrals", body(reason: "a" * 2001)
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "too_long", "reason" ])
      json_post "/psychosocial/referrals", body(reason: "a" * 2000)
      expect(response).to have_http_status(:created)
    end

    it "paciente inexistente → invalid_request patient_id" do
      sign_in_as(doctor)
      json_post "/psychosocial/referrals", body(patient_id: SecureRandom.uuid)
      expect([ json_body["error"], json_body["path"] ]).to eq([ "invalid_request", "patient_id" ])
    end
  end

  describe "leitura pela equipe do CAPS" do
    let(:staff) { caps_staff!(caps) }

    before do
      in_context!
      sign_in_as(doctor)
      json_post "/psychosocial/referrals", body
      @referral_id = json_body["id"]
    end

    it "lista sem o motivo e sem trilha; o detalhe traz o motivo e grava a trilha" do
      sign_in_as(staff)
      expect { get "/psychosocial/referrals", params: { health_unit_id: caps.id, status: "pending" } }.not_to(change { viewed.count })
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(reason)
      item = json_body["items"].sole
      expect(item).to include("id" => @referral_id, "priority" => "priority", "status" => "pending",
                              "from_unit" => { "id" => ubs.id, "name" => "UBS Vila Verde" })
      expect(item.keys).to contain_exactly("id", "patient", "priority", "status", "from_unit", "created_at")
      expect(item["patient"]).to eq(Psychosocial::Json.patient_ref(patient))

      get "/psychosocial/referrals", params: { health_unit_id: caps.id, status: "received" }
      expect(json_body["items"]).to eq([])

      expect { get "/psychosocial/referrals/#{@referral_id}" }.to change { viewed.count }.by(1)
      expect(json_body).to include("reason" => reason, "status" => "pending", "received_at" => nil)
      expect(json_body["referred_by"]).to include("user_id" => doctor.id)
      expect(viewed.last.payload).to include("patient_id" => patient.id, "user_id" => staff.id, "access" => "psychosocial",
                                             "resource" => "referral")
    end

    it "o médico da UBS não lê a fila; outro CAPS → 403 na lista e 404 no detalhe" do
      get "/psychosocial/referrals", params: { health_unit_id: caps.id }
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])

      sign_in_as(caps_staff!(caps!(modality: "caps_ad")))
      get "/psychosocial/referrals", params: { health_unit_id: caps.id }
      expect(json_body["error"]).to eq("not_on_caps_team")
      get "/psychosocial/referrals/#{@referral_id}"
      expect(response).to have_http_status(:not_found)
    end

    it "status fora da lista e chave estranha na query → 422" do
      sign_in_as(staff)
      get "/psychosocial/referrals", params: { health_unit_id: caps.id, status: "done" }
      expect(json_body["path"]).to eq("status")
      get "/psychosocial/referrals", params: { health_unit_id: caps.id, patient_id: patient.id }
      expect(json_body["path"]).to eq("patient_id")
    end
  end
end
