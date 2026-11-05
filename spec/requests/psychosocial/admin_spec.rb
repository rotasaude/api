require "rails_helper"

# Módulo 31 (contrato §3, P9, P22, P26, P27, P33): CAPS no cadastro de
# unidades (/attendance/units, sem step-up), leitos e parâmetros do CAPS.
RSpec.describe "CAPS — administração", type: :request do
  let!(:city) { psychosocial_city! }
  let(:admin) { psychosocial_admin! }

  describe "CAPS no cadastro de unidades (/attendance/units)" do
    before { sign_in_as(admin) }

    it "cadastra CAPS com modalidade, classificação e telefone; recusa modalidade fora do CAPS e classificação inválida" do
      json_post "/attendance/units", name: "CAPS AD III Centro", kind: "caps", caps_modality: "caps_ad_iii",
                                     service_classification: "001", phone: "(41) 3350-1234"
      expect(response).to have_http_status(:created)
      expect(json_body["unit"]).to include("kind" => "caps", "caps_modality" => "caps_ad_iii", "service_classification" => "001",
                                           "phone" => "4133501234")

      json_post "/attendance/units", name: "UBS X", kind: "ubs", caps_modality: "caps_ii"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("caps_modality_mismatch")

      json_post "/attendance/units", name: "CAPS Sem Modalidade", kind: "caps"
      expect(json_body["error"]).to eq("caps_modality_mismatch")

      json_post "/attendance/units", name: "CAPS Z", kind: "caps", caps_modality: "caps_v"
      expect(json_body["error"]).to eq("caps_modality_mismatch")

      json_post "/attendance/units", name: "CAPS Y", kind: "caps", caps_modality: "caps_ii", service_classification: "1A"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("invalid_service_classification")

      json_post "/attendance/units", name: "UBS W", kind: "ubs", service_classification: "001"
      expect(json_body["error"]).to eq("invalid_service_classification")

      json_post "/attendance/units", name: "CAPS Fone", kind: "caps", caps_modality: "caps_ii", phone: "3350-12"
      expect(json_body["error"]).to eq("invalid_phone")
      expect(HealthUnit.where(kind: "caps").count).to eq(1)
    end

    it "edição: mantém a modalidade sem a chave, troca com ela; sair do CAPS limpa as duas; entrar no CAPS exige modalidade" do
      json_post "/attendance/units", name: "CAPS II Norte", kind: "caps", caps_modality: "caps_ii", service_classification: "002"
      id = json_body.dig("unit", "id")

      json_post "/attendance/units/#{id}", name: "CAPS II Norte", kind: "caps", phone: "41998765432"
      expect(response).to have_http_status(:ok)
      expect(json_body["unit"]).to include("caps_modality" => "caps_ii", "service_classification" => "002", "phone" => "41998765432")

      json_post "/attendance/units/#{id}", name: "CAPS III Norte", kind: "caps", caps_modality: "caps_iii", phone: nil,
                                           service_classification: ""
      expect(json_body["unit"]).to include("caps_modality" => "caps_iii", "phone" => nil, "service_classification" => nil)

      json_post "/attendance/units/#{id}", name: "UBS Norte", kind: "ubs"
      expect(response).to have_http_status(:ok)
      expect(json_body["unit"]).to include("kind" => "ubs", "caps_modality" => nil, "service_classification" => nil)

      json_post "/attendance/units/#{id}", name: "CAPS Norte", kind: "caps"
      expect(json_body["error"]).to eq("caps_modality_mismatch")
      expect(HealthUnit.find(id).kind).to eq("ubs")
    end

    # Fix round 1 (Important 1): troca de kind ou de modalidade que deixaria
    # registro do CAPS órfão, leito ativo sem acolhimento noturno ou o nome do
    # CAPS no histórico do cidadão → 409, no padrão do unit_has_ceo_profile.
    it "CAPS com registro do CAPS não sai do CAPS (409 unit_has_caps_records), nem só com leito inativo" do
      night = caps!(modality: "caps_iii", name: "CAPS III Sul")
      bed!(night, label: "L1").update!(active: false)
      json_post "/attendance/units/#{night.id}", name: "UBS Sul", kind: "ubs"
      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to eq("unit_has_caps_records")

      caps = caps!(modality: "caps_ii", name: "CAPS II Leste")
      enrollment!(caps)
      json_post "/attendance/units/#{caps.id}", name: "CAPS II Leste", kind: "upa"
      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to eq("unit_has_caps_records")
      expect([ night.reload.kind, caps.reload.kind, caps.caps_modality ]).to eq(%w[caps caps caps_ii])
    end

    it "CAPS com leito ativo não perde o acolhimento noturno (409 caps_has_beds); leito inativo não prende" do
      night = caps!(modality: "caps_ad_iii", name: "CAPS AD III Oeste")
      bed = bed!(night, label: "L1")
      json_post "/attendance/units/#{night.id}", name: "CAPS AD III Oeste", kind: "caps", caps_modality: "caps_ad"
      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to eq("caps_has_beds")
      json_post "/attendance/units/#{night.id}", name: "CAPS AD III Oeste", kind: "caps", caps_modality: "caps_ad_iv"
      expect(response).to have_http_status(:ok)

      bed.update!(active: false)
      json_post "/attendance/units/#{night.id}", name: "CAPS AD III Oeste", kind: "caps", caps_modality: "caps_ad"
      expect(response).to have_http_status(:ok)
      expect(json_body["unit"]["caps_modality"]).to eq("caps_ad")
    end

    it "unidade com histórico de atendimento não vira CAPS (409 unit_has_attendances)" do
      ubs = HealthUnit.create!(name: "UBS Histórico", kind: "ubs")
      walk_in_attendance!(ubs, citizen: screening_citizen!(1))
      json_post "/attendance/units/#{ubs.id}", name: "UBS Histórico", kind: "caps", caps_modality: "caps_ii"
      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to eq("unit_has_attendances")
      expect(ubs.reload.kind).to eq("ubs")
    end

    it "sem registro nem histórico, a unidade entra e sai do CAPS e troca de modalidade livremente" do
      json_post "/attendance/units", name: "Unidade Livre", kind: "ubs"
      id = json_body.dig("unit", "id")
      json_post "/attendance/units/#{id}", name: "Unidade Livre", kind: "caps", caps_modality: "caps_iii"
      expect(response).to have_http_status(:ok)
      json_post "/attendance/units/#{id}", name: "Unidade Livre", kind: "caps", caps_modality: "caps_ii"
      expect(response).to have_http_status(:ok)
      json_post "/attendance/units/#{id}", name: "Unidade Livre", kind: "hospital"
      expect(response).to have_http_status(:ok)
      expect(json_body["unit"]).to include("kind" => "hospital", "caps_modality" => nil)
    end

    it "a lista das unidades mostra os campos do CAPS" do
      caps = caps!(modality: "caps_i")
      get "/attendance/units"
      row = json_body["units"].find { |u| u["id"] == caps.id }
      expect(row).to include("kind" => "caps", "caps_modality" => "caps_i", "service_classification" => "001", "phone" => nil)
    end
  end

  describe "leitos (/psychosocial/beds)" do
    before { stepped_up!(admin) }

    it "leito só em CAPS III, AD III e AD IV; rótulo único no CAPS (409); edição e desativação" do
      json_post "/psychosocial/beds", health_unit_id: caps!(modality: "caps_ii").id, label: "L1"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("caps_without_beds")

      night = caps!(modality: "caps_iii")
      json_post "/psychosocial/beds", health_unit_id: night.id, label: " L1 "
      expect(response).to have_http_status(:created)
      bed_id = json_body["id"]
      expect(json_body).to eq("id" => bed_id, "health_unit_id" => night.id, "label" => "L1", "active" => true)

      json_post "/psychosocial/beds", health_unit_id: night.id, label: "L1"
      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to eq("bed_label_taken")

      json_patch "/psychosocial/beds/#{bed_id}", label: "L2", active: false
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("label" => "L2", "active" => false)

      json_patch "/psychosocial/beds/#{bed_id}", health_unit_id: caps!(modality: "caps_ad_iii").id
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")

      json_post "/psychosocial/beds", health_unit_id: night.id, label: "L" * 21, extra: 1
      expect(json_body["problems"].map { |p| p["path"] }).to eq(%w[extra])
      json_post "/psychosocial/beds", health_unit_id: night.id, label: "L" * 21
      expect(json_body).to include("error" => "invalid_request", "path" => "label")
      json_post "/psychosocial/beds", health_unit_id: SecureRandom.uuid, label: "L3"
      expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")

      json_patch "/psychosocial/beds/#{SecureRandom.uuid}", label: "L3"
      expect(response).to have_http_status(:not_found)

      bed!(night, label: "L0")
      bed!(caps!(modality: "caps_ad_iv"), label: "X1")
      get "/psychosocial/beds", params: { health_unit_id: night.id }
      expect(json_body["items"].map { |b| b["label"] }).to eq(%w[L0 L2])
      get "/psychosocial/beds"
      expect(json_body).to include("error" => "invalid_request", "path" => "health_unit_id")
    end

    it "escrita exige step-up; só o municipal_admin" do
      night = caps!(modality: "caps_ad_iii")
      sign_in_as(admin)
      json_post "/psychosocial/beds", health_unit_id: night.id, label: "L1"
      expect(response).to have_http_status(:unauthorized)
      expect(json_body["error"]).to eq("mfa_required")

      stepped_up!(caps_staff!(night, lead: true))
      json_post "/psychosocial/beds", health_unit_id: night.id, label: "L1"
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_role")
      get "/psychosocial/beds", params: { health_unit_id: night.id }
      expect(response).to have_http_status(:forbidden)
      expect(PsychosocialBed.count).to eq(0)
    end
  end

  describe "parâmetros (/psychosocial/settings)" do
    it "leitura e escrita parcial com evento sem payload; recusas com path" do
      stepped_up!(admin)
      get "/psychosocial/settings"
      expect(json_body).to eq("night_limits" => Psychosocial::Catalog::DEFAULT_NIGHT_LIMITS, "care_plan_review_days" => 90)

      json_patch "/psychosocial/settings", night_limits: { caps_ii: { total: 3, window_days: 30 } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "invalid_request", "path" => "night_limits.caps_ii")

      json_patch "/psychosocial/settings", night_limits: { caps_iii: { consecutive: 0, alternate: 10, window_days: 30 } }
      expect(json_body["path"]).to eq("night_limits.caps_iii.consecutive")
      json_patch "/psychosocial/settings", night_limits: { caps_ad_iii: { total: 14 } }
      expect(json_body["path"]).to eq("night_limits.caps_ad_iii")
      json_patch "/psychosocial/settings", night_limits: { caps_ad_iv: { total: 14, window_days: 120 } }
      expect(json_body["path"]).to eq("night_limits.caps_ad_iv.window_days")
      json_patch "/psychosocial/settings", care_plan_review_days: 29, other: 1
      expect(json_body["problems"]).to eq([ { "path" => "other", "error" => "invalid_request" } ])
      json_patch "/psychosocial/settings", care_plan_review_days: 29
      expect(json_body["path"]).to eq("care_plan_review_days")

      expect { json_patch "/psychosocial/settings", care_plan_review_days: 60 }
        .to change { DomainEvent.where(name: "psychosocial.settings_changed").count }.by(1)
      expect(DomainEvent.where(name: "psychosocial.settings_changed").sole.payload).to eq({})
      expect(json_body["care_plan_review_days"]).to eq(60)

      expect { json_patch "/psychosocial/settings", care_plan_review_days: 60 }
        .not_to(change { DomainEvent.where(name: "psychosocial.settings_changed").count })

      json_patch "/psychosocial/settings", night_limits: { caps_ad_iv: { total: 10, window_days: 20 } }
      expect(response).to have_http_status(:ok)
      expect(json_body["night_limits"]).to eq(Psychosocial::Catalog::DEFAULT_NIGHT_LIMITS
                                                .merge("caps_ad_iv" => { "total" => 10, "window_days" => 20 }))
      expect(PsychosocialSetting.current.updated_by_user_id).to eq(admin.id)
    end

    it "leitura pela coordenação (P33); escrita só do admin com step-up; equipe e analista não leem" do
      caps = caps!(modality: "caps_ad_iii")
      sign_in_as(caps_staff!(caps, lead: true))
      get "/psychosocial/settings"
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to contain_exactly("night_limits", "care_plan_review_days")

      stepped_up!(caps_staff!(caps, lead: true))
      json_patch "/psychosocial/settings", care_plan_review_days: 60
      expect(response).to have_http_status(:forbidden)

      sign_in_as(caps_staff!(caps))
      get "/psychosocial/settings"
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_role")

      sign_in_as(admin)
      json_patch "/psychosocial/settings", care_plan_review_days: 60
      expect(response).to have_http_status(:unauthorized)
      expect(PsychosocialSetting.current.care_plan_review_days).to eq(90)
    end
  end

  describe "interruptor (P22, sem cascata)" do
    it "desligado → 403 feature_disabled em toda rota do CAPS" do
      stepped_up!(admin)
      Platform::Features.set!(city: city, key: "psychosocial_care", enabled: false, maintainer: ledi_maintainer!)
      get "/psychosocial/settings"
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "psychosocial_care")
      json_post "/psychosocial/beds", health_unit_id: caps!(modality: "caps_iii").id, label: "L1"
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "psychosocial_care")
      get "/psychosocial/units"
      expect(response).to have_http_status(:forbidden)
    end

    it "prontuário desligado: o CAPS segue ligado, falta pré-requisito e as rotas respondem 403" do
      stepped_up!(admin)
      Platform::Features.set!(city: city, key: "clinical_record", enabled: false, maintainer: ledi_maintainer!)
      get "/psychosocial/settings"
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "psychosocial_care")
      expect(CityFeature.find_by(city_id: city.id, key: "psychosocial_care").enabled).to be(true)
      expect(Platform::Features.missing(city, "psychosocial_care")).to eq(%w[clinical_record_disabled])
    end
  end
end
