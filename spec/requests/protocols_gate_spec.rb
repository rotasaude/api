require "rails_helper"

RSpec.describe "POST /protocols/:name/gate", type: :request do
  let(:headers) { { "Authorization" => "Bearer any-token" } }

  def valid_def
    {
      "name" => "respiratoria", "version" => 1, "start_step_id" => "tosse",
      "steps" => [
        { "id" => "tosse", "prompt" => "Tosse?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }
  end

  it "returns valid:true for a gate-valid definition" do
    post "/protocols/respiratoria/gate", params: { definition: valid_def }, as: :json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq("valid" => true)
  end

  it "returns 422 with errors for a definition that fails the gate" do
    bad = valid_def
    bad["scoring"]["priority_map"]["baixa"] = 99   # out of schema range
    post "/protocols/respiratoria/gate", params: { definition: bad }, as: :json, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    body = JSON.parse(response.body)
    expect(body["valid"]).to be false
    expect(body["errors"]).to be_present
  end

  it "requires an Authorization header" do
    post "/protocols/respiratoria/gate", params: { definition: valid_def }, as: :json
    expect(response).to have_http_status(:unauthorized)
  end
end
