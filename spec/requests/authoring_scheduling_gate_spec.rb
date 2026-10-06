require "rails_helper"

# Contratos §1/§9: o gate valida scheduling[].when (Protocols::Validation::Scheduling)
# e só avisa tipo inexistente ou desativado na cidade (200 + warnings).
RSpec.describe "POST /authoring/protocols/gate com scheduling", type: :request do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:author) { staff_with("autoria-#{SecureRandom.hex(3)}@cidade.gov.br", "protocol_author") }
  let(:rule) do
    { "when" => { "gte" => ["outcome.score", 3] }, "appointment_type" => "fantasma",
      "priority" => "routine", "due_in_days" => 30 }
  end

  def definition(scheduling)
    { "name" => "saude-do-idoso", "version" => 1, "start_step_id" => "s1",
      "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                     "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 4, "false" => 0 } } ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "media" => 3 },
                     "priority_map" => { "baixa" => 9, "media" => 5 } },
      "scheduling" => scheduling }
  end

  it "tipo inexistente ou desativado: válido, 200 com warnings" do
    type_row!("acupuntura", active: false)
    type_row!("consulta_medica")
    sign_in_as(author)
    rules = [ rule, rule.merge("appointment_type" => "acupuntura"), rule.merge("appointment_type" => "consulta_medica") ]
    json_post "/authoring/protocols/gate", definition: definition(rules)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq(
      "valid" => true,
      "warnings" => [ "scheduling appointment_type 'fantasma' does not exist in this city",
                      "scheduling appointment_type 'acupuntura' is inactive in this city" ]
    )
  end

  it "variável proibida no when: o gate chega a Validation::Scheduling e responde 422" do
    allow(Protocols::Validation::Scheduling).to receive(:call).and_call_original
    sign_in_as(author)
    json_post "/authoring/protocols/gate",
              definition: definition([ rule.merge("when" => { "eq" => ["citizen.neighborhood_id", SecureRandom.uuid] }) ])

    expect(response).to have_http_status(:unprocessable_content)
    expect(Protocols::Validation::Scheduling).to have_received(:call).once
    errors = JSON.parse(response.body)["errors"]
    expect(errors).to include(a_string_starting_with("scheduling[0].when: "))
    # Como no módulo 15: o 422 também leva os avisos.
    expect(JSON.parse(response.body)["warnings"])
      .to eq([ "scheduling appointment_type 'fantasma' does not exist in this city" ])
  end
end
