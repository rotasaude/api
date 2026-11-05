require "rails_helper"

# Módulo 31 (contrato §4, P12, P13, P25): grade semanal de grupos do CAPS.
# Escrita do psychosocial_staff lotado, sem step-up; sem trilha nem evento
# (cadastro sem paciente); o grupo nunca é apagado (desativa-se).
RSpec.describe "CAPS — grade de grupos", type: :request do
  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps) }
  let(:viewed) { DomainEvent.where(name: "clinical_record.viewed") }

  def body(**over)
    { health_unit_id: caps.id, name: "Oficina de artesanato", kind: "workshop", weekday: 3, starts_at: "14:00", ends_at: "16:00",
      responsible_user_id: staff.id, capacity: 12, sigtap_code: "0301080216" }.merge(over)
  end

  def group!(**over)
    PsychosocialGroup.create!({ health_unit: caps, name: "Grupo", kind: "group", weekday: 3, starts_at: "10:00", ends_at: "11:00",
                                responsible_user: staff, capacity: 10, sigtap_code: "0301080216", updated_by_user: staff }.merge(over))
  end

  before { sign_in_as(staff) }

  describe "POST /psychosocial/groups" do
    it "grava o grupo, devolve 201 com horas HH:MM e o responsável, sem trilha, sem step-up" do
      expect { json_post "/psychosocial/groups", body }.not_to(change { [ viewed.count, DomainEvent.count ] })
      expect(response).to have_http_status(:created)
      expect(json_body).to include("health_unit_id" => caps.id, "name" => "Oficina de artesanato", "kind" => "workshop", "weekday" => 3,
                                   "starts_at" => "14:00", "ends_at" => "16:00", "capacity" => 12, "sigtap_code" => "0301080216",
                                   "active" => true)
      expect(json_body["responsible"]).to eq(Psychosocial::Json.pro(staff, "251510"))
      saved = PsychosocialGroup.find(json_body["id"])
      expect(saved.updated_by_user_id).to eq(staff.id)
      # a hora gravada é a que foi enviada, não deslocada pelo fuso
      expect(PsychosocialGroup.connection.select_value("SELECT starts_at::text FROM psychosocial_groups WHERE id = '#{saved.id}'"))
        .to eq("14:00:00")
    end

    it "aceita código BPA-C (01) e o nome de até 120 caracteres; 121 → too_long" do
      json_post "/psychosocial/groups", body(sigtap_code: "0301080259", name: "n" * 120)
      expect(response).to have_http_status(:created)
      json_post "/psychosocial/groups", body(name: "n" * 121)
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "too_long", "name" ])
    end

    it "fim antes do início (ou igual) → path ends_at, nada gravado" do
      [ "13:59", "14:00" ].each do |ends_at|
        expect { json_post "/psychosocial/groups", body(ends_at: ends_at) }.not_to change(PsychosocialGroup, :count)
        expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "ends_at" ])
      end
    end

    it "código sem instrumento 09 nem 01 → instrument_mismatch `sigtap_code`; código fora da forma → invalid_request" do
      json_post "/psychosocial/groups", body(sigtap_code: "0301010064")
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "instrument_mismatch", "sigtap_code" ])
      json_post "/psychosocial/groups", body(sigtap_code: "9999999999")
      expect(json_body["error"]).to eq("instrument_mismatch")
      json_post "/psychosocial/groups", body(sigtap_code: "abc")
      expect([ json_body["error"], json_body["path"] ]).to eq([ "invalid_request", "sigtap_code" ])
    end

    it "campos fora da forma e chave desconhecida, todos de uma vez; faltando campo obrigatório" do
      json_post "/psychosocial/groups", body(kind: "roda", weekday: 8, starts_at: "25:00", capacity: 0, active: "sim", extra: 1)
      expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly("kind", "weekday", "starts_at", "capacity", "active", "extra")

      json_post "/psychosocial/groups", body.except(:name, :capacity)
      expect(json_body["problems"].map { |p| p["path"] }).to contain_exactly("name", "capacity")
      expect(PsychosocialGroup.count).to eq(0)
    end

    it "responsável fora da equipe do CAPS → path responsible_user_id" do
      outsider = caps_staff!(caps!(modality: "caps_ad"))
      json_post "/psychosocial/groups", body(responsible_user_id: outsider.id)
      expect([ response.status, json_body["path"] ]).to eq([ 422, "responsible_user_id" ])
      json_post "/psychosocial/groups", body(responsible_user_id: "x")
      expect(json_body["path"]).to eq("responsible_user_id")
    end

    it "equipe de outro CAPS → 403 not_on_caps_team; papel fora do CAPS → 403 missing_role; CAPS inexistente → 422" do
      other = caps!(modality: "caps_ad")
      json_post "/psychosocial/groups", body(health_unit_id: other.id)
      expect([ response.status, json_body["error"] ]).to eq([ 403, "not_on_caps_team" ])
      json_post "/psychosocial/groups", body(health_unit_id: SecureRandom.uuid)
      expect([ response.status, json_body["path"] ]).to eq([ 422, "health_unit_id" ])

      sign_in_as(ubs_doctor!(create_unit))
      json_post "/psychosocial/groups", body
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
      expect(PsychosocialGroup.count).to eq(0)
    end

    it "dado na query → 422 com o path" do
      post "/psychosocial/groups?name=segredo", params: body.to_json, headers: { "CONTENT_TYPE" => "application/json" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "name" ])
    end
  end

  describe "PATCH /psychosocial/groups/:id" do
    it "muda só o que foi enviado; desativa; o resto fica" do
      group = group!
      json_patch "/psychosocial/groups/#{group.id}", { name: "Grupo de manhã", active: false, starts_at: "09:00" }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("name" => "Grupo de manhã", "active" => false, "starts_at" => "09:00", "ends_at" => "11:00",
                                   "weekday" => 3, "capacity" => 10)
      expect(group.reload).to have_attributes(name: "Grupo de manhã", active: false)
    end

    it "editar só um horário que fica depois do outro → path ends_at; o nome muda sem rever a SIGTAP" do
      group = group!
      json_patch "/psychosocial/groups/#{group.id}", { starts_at: "11:30" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "ends_at" ])
      expect(group.reload.starts_at.strftime("%H:%M")).to eq("10:00")

      group.update_columns(sigtap_code: "0301010064")
      json_patch "/psychosocial/groups/#{group.id}", { name: "Só o nome" }
      expect(response).to have_http_status(:ok)
      json_patch "/psychosocial/groups/#{group.id}", { sigtap_code: "0301010064x" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    # Revisão final (minor da T6): reativar confere de novo o código SIGTAP e o
    # responsável gravados, como se fossem novos.
    it "reativar (active false → true) confere a SIGTAP e o responsável; trocados no mesmo PATCH, valem os novos" do
      group = group!(active: false)
      group.update_columns(sigtap_code: "0301010064")
      json_patch "/psychosocial/groups/#{group.id}", { active: true }
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "instrument_mismatch", "sigtap_code" ])
      expect(group.reload.active).to be(false)

      json_patch "/psychosocial/groups/#{group.id}", { active: true, sigtap_code: "0301080216" }
      expect(response).to have_http_status(:ok)
      expect(group.reload).to have_attributes(active: true, sigtap_code: "0301080216")

      group.update_columns(active: false)
      ProfessionalLink.active.where(health_unit_id: caps.id).find_each { |l| l.update!(ended_at: Time.current, ended_by_user: staff) }
      other = caps_staff!(caps)
      sign_in_as(other)
      json_patch "/psychosocial/groups/#{group.id}", { active: true }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "responsible_user_id" ])
      json_patch "/psychosocial/groups/#{group.id}", { active: true, responsible_user_id: other.id }
      expect(response).to have_http_status(:ok)
      expect(group.reload).to have_attributes(active: true, responsible_user_id: other.id)
    end

    it "troca de CAPS não vale; nome acima de 120 → too_long" do
      group = group!
      json_patch "/psychosocial/groups/#{group.id}", { health_unit_id: caps!(modality: "caps_ad").id }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "health_unit_id" ])
      json_patch "/psychosocial/groups/#{group.id}", { name: "n" * 121 }
      expect(json_body["error"]).to eq("too_long")
    end

    it "grupo de outro CAPS ou id malformado → 404; papel fora do CAPS → 403" do
      other = PsychosocialGroup.create!(health_unit: caps!(modality: "caps_ad"), name: "Outro", kind: "group", weekday: 1,
                                        starts_at: "08:00", ends_at: "09:00", responsible_user: staff, capacity: 5,
                                        sigtap_code: "0301080216", updated_by_user: staff)
      json_patch "/psychosocial/groups/#{other.id}", { name: "Invadido" }
      expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
      expect(other.reload.name).to eq("Outro")
      json_patch "/psychosocial/groups/nao-e-uuid", { name: "x" }
      expect(response).to have_http_status(:not_found)

      sign_in_as(ubs_doctor!(create_unit))
      json_patch "/psychosocial/groups/#{other.id}", { name: "x" }
      expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    end
  end

  describe "GET /psychosocial/groups" do
    it "lista a grade do CAPS por dia e hora, só ativos com ?active=true; sem trilha" do
      quinta = group!(name: "Quinta", weekday: 4)
      tarde = group!(name: "Quarta tarde", starts_at: "14:00", ends_at: "15:00")
      manha = group!(name: "Quarta manhã")
      velho = group!(name: "Velho", active: false)
      group!(name: "De outro CAPS", health_unit: caps!(modality: "caps_ad"), responsible_user: staff)

      expect { get "/psychosocial/groups", params: { health_unit_id: caps.id } }.not_to(change { viewed.count })
      expect(json_body["items"].map { |g| g["id"] }).to eq([ manha, velho, tarde, quinta ].map(&:id))

      get "/psychosocial/groups", params: { health_unit_id: caps.id, active: "true" }
      expect(json_body["items"].map { |g| g["id"] }).to eq([ manha, tarde, quinta ].map(&:id))
      get "/psychosocial/groups", params: { health_unit_id: caps.id, active: "false" }
      expect(json_body["items"].map { |g| g["id"] }).to eq([ velho.id ])
      get "/psychosocial/groups", params: { health_unit_id: caps.id, active: "talvez" }
      expect([ response.status, json_body["path"] ]).to eq([ 422, "active" ])
    end

    it "CAPS onde não está lotado → 403; sem health_unit_id → 422" do
      get "/psychosocial/groups", params: { health_unit_id: caps!(modality: "caps_ad").id }
      expect([ response.status, json_body["error"] ]).to eq([ 403, "not_on_caps_team" ])
      get "/psychosocial/groups"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "health_unit_id" ])
    end
  end
end
