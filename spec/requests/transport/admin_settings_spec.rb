require "rails_helper"

RSpec.describe "Transporte — configuração", type: :request do
  let!(:city) { transport_city! }
  let(:admin) { staff_with("adm-transporte@cidade.gov.br", "municipal_admin") }

  it "lê o padrão (com allowance_codes) e grava; a unidade do TFD precisa ser health_management com CNES" do
    tfd_sigtap!
    stepped_up!(admin)
    get "/transport/admin/settings"
    expect(json_body.except("allowance_codes")).to eq("tfd_min_distance_km" => 50, "companion_rule" => { "max_age_child" => 15, "min_age_elderly" => 60 },
                                                      "tfd_billing_health_unit_id" => nil, "allowance_complements" => {})
    codes = json_body["allowance_codes"]
    expect(codes.size).to eq(10)
    expect(codes).to include("code" => "0803010044", "name" => "AJUDA DE CUSTO PARA ALIMENTACAO/PERNOITE DE ACOMPANHANTE", "kind" => "meal_overnight")
    json_patch "/transport/admin/settings", tfd_billing_health_unit_id: create_unit("UBS Centro").id
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "billing_unit_invalid", "tfd_billing_health_unit_id" ])
    expect(TransportSetting.current.tfd_billing_health_unit_id).to be_nil
    unit = health_management_unit!
    json_patch "/transport/admin/settings", tfd_billing_health_unit_id: unit.id, allowance_complements: { "0803010044" => 5000 }, tfd_min_distance_km: 60
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("tfd_min_distance_km" => 60, "tfd_billing_health_unit_id" => unit.id, "allowance_complements" => { "0803010044" => 5000 })
    expect(TransportSetting.current.updated_by_user_id).to eq(admin.id)
  end

  it "unidade de gestão sem CNES, id inexistente e desvinculo" do
    stepped_up!(admin)
    no_cnes = HealthUnit.create!(name: "Central sem CNES", kind: "health_management")
    json_patch "/transport/admin/settings", tfd_billing_health_unit_id: no_cnes.id
    expect(json_body["error"]).to eq("billing_unit_invalid")
    json_patch "/transport/admin/settings", tfd_billing_health_unit_id: SecureRandom.uuid
    expect(json_body["error"]).to eq("billing_unit_invalid")
    unit = health_management_unit!
    json_patch "/transport/admin/settings", tfd_billing_health_unit_id: unit.id
    json_patch "/transport/admin/settings", tfd_billing_health_unit_id: nil
    expect(json_body["tfd_billing_health_unit_id"]).to be_nil
  end

  it "recusas de campo vêm todas de uma vez; nada é gravado" do
    stepped_up!(admin)
    json_patch "/transport/admin/settings", tfd_min_distance_km: 0, companion_rule: { "max_age_child" => 30, "min_age_elderly" => 60 }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body["problems"].map { |p| p["path"] }).to eq(%w[tfd_min_distance_km companion_rule.max_age_child])
    json_patch "/transport/admin/settings", companion_rule: { "max_age_child" => 12 }
    expect(json_body["path"]).to eq("companion_rule")
    json_patch "/transport/admin/settings", segredo: 1
    expect([ json_body["error"], json_body["path"] ]).to eq([ "invalid_request", "segredo" ])
    expect(TransportSetting.current.tfd_min_distance_km).to eq(50)
    json_patch "/transport/admin/settings", companion_rule: { "max_age_child" => 12, "min_age_elderly" => 65 }
    expect(json_body["companion_rule"]).to eq("max_age_child" => 12, "min_age_elderly" => 65)
  end

  it "complemento só para código do sigtap_codes.yml e em centavos inteiros; sem step-up → 401; desligado → 403" do
    session = stepped_up!(admin)
    json_patch "/transport/admin/settings", allowance_complements: { "0301010072" => 100 }
    expect(json_body["path"]).to eq("allowance_complements.0301010072")
    json_patch "/transport/admin/settings", allowance_complements: { "0803010044" => 10.5 }
    expect(json_body["path"]).to eq("allowance_complements.0803010044")
    session.update!(mfa_verified_at: 10.minutes.ago)
    json_patch "/transport/admin/settings", tfd_min_distance_km: 70
    expect(response).to have_http_status(:unauthorized)
    expect(json_body).to eq("error" => "mfa_required")
    Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
    get "/transport/admin/settings"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "sanitary_transport")
  end

  # Coordenador T27: como o vaccination.settings_changed, só o id da cidade e
  # os NOMES das chaves que mudaram — nunca os valores.
  it "a troca publica transport.settings_changed com o id da cidade e os nomes das chaves; sem troca ou recusada, nada" do
    stepped_up!(admin)
    unit = health_management_unit!
    events = -> { DomainEvent.where(name: "transport.settings_changed").order(:created_at, :id) }
    expect do
      json_patch "/transport/admin/settings", tfd_min_distance_km: 61, companion_rule: { "max_age_child" => 14, "min_age_elderly" => 60 },
                                              tfd_billing_health_unit_id: unit.id, allowance_complements: { "0803010044" => 5000 }
    end.to change { events.call.count }.by(1)
    payload = events.call.last.payload
    expect(payload).to eq("city_id" => city.id, "changed" => %w[allowance_complements companion_rule tfd_billing_health_unit_id tfd_min_distance_km])
    expect { json_patch "/transport/admin/settings", tfd_min_distance_km: 61, allowance_complements: { "0803010044" => 5000 } }
      .not_to(change { events.call.count })
    expect { json_patch "/transport/admin/settings", tfd_min_distance_km: 0 }.not_to(change { events.call.count })
    json_patch "/transport/admin/settings", companion_rule: { "max_age_child" => 14, "min_age_elderly" => 65 }
    expect(events.call.last.payload).to eq("city_id" => city.id, "changed" => %w[companion_rule])
  end

  it "quem não é municipal_admin → 403 missing_role" do
    sign_in_as(dispatcher!)
    get "/transport/admin/settings"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
  end
end
