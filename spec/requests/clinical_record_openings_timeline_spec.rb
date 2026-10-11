require "rails_helper"

# Divergência D5: a abertura vale com patient_timeline ligado mesmo sem o
# prontuário utilizável; patient_id nulo quando a pessoa não tem paciente; o
# relatório mostra o CPF mascarado do par.
RSpec.describe "Abertura justificada pela pessoa", type: :request do
  let(:unit) { create_unit }
  let(:nurse) { doctor!(unit, cbo: "223505") }
  def body = JSON.parse(response.body)

  it "modo integrado: cria pelo par e aparece no relatório" do
    timeline_city!(record_mode: "integrated", clinical_record: false)
    citizen = verified_citizen!(47)
    stepped_up!(nurse)
    json_post "/clinical_record/openings", cpf: citizen.cpf, reason_code: "active_search"
    expect(response).to have_http_status(:created)
    expect(body.keys).to match_array(%w[opening_id patient_id expires_at])
    expect(body["patient_id"]).to be_nil

    sign_in_as(staff_with("adm-tl@cidade.gov.br", "municipal_admin"))
    get "/clinical_record/openings"
    expect(body["items"].sole).to include("kind" => "justified_opening", "cpf_masked" => citizen.cpf_masked)
  end

  it "sem patient_timeline e sem prontuário: 403 feature_disabled como no 19a" do
    clinical_city!(record_mode: "integrated", enabled: false)
    stepped_up!(nurse)
    json_post "/clinical_record/openings", cpf: verified_citizen!(48).cpf, reason_code: "active_search"
    expect([ response.status, body["error"], body["feature"] ]).to eq([ 403, "feature_disabled", "clinical_record" ])
  end
end
