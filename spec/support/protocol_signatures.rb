# Arranjo de protocolo e assinaturas para specs de domínio. Os exemplos rodam
# na conexão de TEST_CITY_A (city_test_databases.rb), então o que se cria aqui
# é visível pelos commands.
module ProtocolSignaturesSpecHelpers
  # O mesmo protocolo de spec/commands/protocols_lifecycle_spec.rb, que passa
  # no portão (Protocols::Gate).
  def protocol_definition_hash(name: "dengue", version: 1)
    {
      "name" => name, "version" => version, "start_step_id" => "s1",
      "steps" => [
        { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 1, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }
  end

  def make_reviewer!(email: "rv-#{SecureRandom.hex(4)}@example.org")
    user = User.create!(email_address: email, password: "secret123")
    Membership.create!(user: user, role: "protocol_reviewer", granted_at: Time.current)
    user
  end

  def sign!(protocol, purpose:, by:)
    ProtocolSignature.create!(protocol_definition: protocol, purpose: purpose, signer: by,
                              content_digest: protocol.reload.content_digest)
  end
end

RSpec.configure { |config| config.include ProtocolSignaturesSpecHelpers }
