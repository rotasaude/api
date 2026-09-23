# Protocolo de dois passos booleanos, o mesmo de config/city_templates/
# triage_respiratoria.json: tosse (true → febre, false → fim) e febre (fim).
module TriageProtocolHelpers
  def create_default_protocol!
    ProtocolDefinition.create!(
      name: StartTriage::DEFAULT_PROTOCOL_NAME, version: 1, status: "active",
      definition: {
        "name" => StartTriage::DEFAULT_PROTOCOL_NAME, "version" => 1, "start_step_id" => "tosse",
        "steps" => [
          { "id" => "tosse", "prompt" => "Você está com tosse?", "answer_type" => "boolean",
            "branches" => { "true" => "febre", "false" => nil }, "weights" => { "true" => 3, "false" => 0 } },
          { "id" => "febre", "prompt" => "Está com febre alta?", "answer_type" => "boolean",
            "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
        ],
        "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                       "priority_map" => { "baixa" => 9, "alta" => 1 } }
      }
    )
  end
end

RSpec.configure { |c| c.include TriageProtocolHelpers }
