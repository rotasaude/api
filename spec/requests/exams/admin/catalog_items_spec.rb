require "rails_helper"

# Contrato §5: catálogo da cidade, municipal_admin, escrita com step-up.
RSpec.describe "Catálogo de exames (admin)", type: :request do
  before { exam_city! }

  let(:admin) { municipal_admin! }
  let(:body) do
    { sigtap_code: "0202010503", requires_authorization: false, release_policy: "immediate",
      deadlines: { "result" => 10 }, active: true,
      result_fields: [ { key: "hba1c", label: "Hemoglobina glicada", unit: "%", loinc: "4548-4" } ] }
  end

  it "cria, lista e altera; sem step-up 401; sem papel 403; interruptor desligado 403" do
    sign_in_as(step_up_enrolled!(admin))
    json_post "/exams/admin/catalog_items", body
    expect([ response.status, json_body["error"] ]).to eq([ 401, "mfa_required" ])
    stepped_up!(municipal_admin!)
    json_post "/exams/admin/catalog_items", body
    expect(response).to have_http_status(:created)
    created = json_body
    expect(created).to include("sigtap_code" => "0202010503", "label" => "DOSAGEM DE HEMOGLOBINA GLICOSILADA",
                               "release_policy" => "immediate", "requires_authorization" => false, "active" => true)
    expect(created["deadlines"]).to eq("authorize" => nil, "schedule" => nil, "collect" => nil, "result" => 10, "acknowledge" => nil)
    json_post "/exams/admin/catalog_items", body
    expect([ response.status, json_body["error"] ]).to eq([ 422, "duplicate_sigtap" ])
    patch "/exams/admin/catalog_items/#{created['id']}", params: { release_policy: "never_citizen" }.to_json,
                                                       headers: { "CONTENT_TYPE" => "application/json" }
    expect(json_body["release_policy"]).to eq("never_citizen")
    get "/exams/admin/catalog_items"
    expect(json_body["items"].map { |i| i["sigtap_code"] }).to eq(%w[0202010503])

    sign_in_as(staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier"))
    get "/exams/admin/catalog_items"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
    Platform::Features.set!(city: Current.city, key: "exam_tracking", enabled: false, maintainer: ledi_maintainer!)
    get "/exams/admin/catalog_items"
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "exam_tracking")
  end

  it "recusa SIGTAP fora da competência vigente, prazo fora de 1..365, política e campos ruins" do
    stepped_up!(admin)
    { { sigtap_code: "0202999999" } => "sigtap_unknown", { sigtap_code: "0301010064" } => "sigtap_unknown",
      { deadlines: { "result" => 0 } } => "invalid_deadline", { deadlines: { "lunch" => 3 } } => "invalid_deadline",
      { release_policy: "sometimes" } => "invalid_policy",
      { result_fields: [ { key: "Bad Key", label: "x" } ] } => "invalid_result_fields",
      { result_fields: [ { key: "a", label: "x" }, { key: "a", label: "y" } ] } => "invalid_result_fields" }.each do |over, error|
      json_post "/exams/admin/catalog_items", body.merge(over)
      expect([ response.status, json_body["error"] ]).to eq([ 422, error ]), over.inspect
    end
  end
end
