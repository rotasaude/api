require "rails_helper"

# Contrato §6 com B10: admin municipal; GET 200 com nulls; PUT com
# step-up; larguras do layout recusadas (nunca cortadas), com o campo;
# CNPJ só numérico (o campo do cabeçalho é NUM) — Review Focus 5.
RSpec.describe "Faturamento — configuração", type: :request do
  before { billing_city! }

  let(:admin) { lab_admin! }
  let(:valid) do
    { origin_name: "SMS Curitiba", origin_acronym: "SMS", origin_cnpj: "11.222.333/0001-81", destination_body: "Secretaria Municipal de Saúde",
      management: "M" }
  end

  it "GET sem configuração: 200 com nulls; faturista não lê" do
    sign_in_as(admin)
    get "/billing/settings"
    expect(json_body).to eq("origin_name" => nil, "origin_acronym" => nil, "origin_cnpj" => nil, "destination_body" => nil,
                            "management" => nil, "updated_at" => nil)
    sign_in_as(billing_clerk!)
    get "/billing/settings"
    expect(response).to have_http_status(:forbidden)
  end

  it "PUT com step-up grava e publica só ids" do
    sign_in_as(admin)
    json_put "/billing/settings", valid
    expect(json_body).to eq("error" => "mfa_required")
    stepped_up!(admin)
    json_put "/billing/settings", valid
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("origin_name" => "SMS Curitiba", "origin_acronym" => "SMS", "origin_cnpj" => "11222333000181", "management" => "M")
    expect(DomainEvent.where(name: "billing_settings.changed").last.payload.keys).to match_array(%w[billing_setting_id user_id])
    json_put "/billing/settings", valid.merge(management: "E", origin_acronym: "")
    expect(BillingSetting.count).to eq(1)
    expect(BillingSetting.current).to have_attributes(management: "E", origin_acronym: nil)
  end

  it "recusas: campos, larguras, CNPJ alfanumérico e indicador; nada gravado" do
    stepped_up!(admin)
    {
      { origin_name: " " } => { "error" => "field_required", "field" => "origin_name" },
      { origin_name: "S" * 31 } => { "error" => "too_long", "field" => "origin_name" },
      { origin_acronym: "SMSCURI" } => { "error" => "too_long", "field" => "origin_acronym" },
      { destination_body: "" } => { "error" => "field_required", "field" => "destination_body" },
      { destination_body: "D" * 41 } => { "error" => "too_long", "field" => "destination_body" },
      { origin_cnpj: "11.222.333/0001-82" } => { "error" => "invalid_cnpj" },
      { origin_cnpj: "12.ABC.345/01DE-35" } => { "error" => "invalid_cnpj" },
      { management: "X" } => { "error" => "invalid_management" }
    }.each do |over, error|
      json_put "/billing/settings", valid.merge(over)
      expect(json_body).to eq(error), over.inspect
    end
    expect(BillingSetting.count).to eq(0)
  end
end
