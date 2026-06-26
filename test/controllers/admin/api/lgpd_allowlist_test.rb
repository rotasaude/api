require "test_helper"

# Critério de aceite §10: NENHUM endpoint do namespace Admin:: pode emitir
# campo clínico cru (inbound_messages.raw, triagens.answers, consents.evidence).
#
# Estratégia: gravar dados com sentinelas únicas em cada campo proibido,
# bater todos os endpoints e falhar se a sentinela aparecer em QUALQUER
# resposta JSON.
class Admin::Api::LgpdAllowlistTest < ActionDispatch::IntegrationTest
  SENTINELS = {
    inbound_raw:    "SENTINEL_INBOUND_RAW_42aa3f",
    triagem_answer: "SENTINEL_TRIAGEM_ANSWER_b7c91d",
    consent_evid:   "SENTINEL_CONSENT_EVIDENCE_1e88a0"
  }.freeze

  ENDPOINTS = %w[
    /admin/api/overview
    /admin/api/ingestion
    /admin/api/conversations
    /admin/api/consent
    /admin/api/triages
    /admin/api/classification
    /admin/api/protocols
    /admin/api/queues
    /admin/api/events
    /admin/api/health
    /admin/api/municipalities
  ].freeze

  setup do
    @user = User.create!(
      email_address: "lgpd-#{SecureRandom.hex(4)}@test.local",
      password: "lgpd-password"
    )
    seed_sentinels!
    login!
  end

  test "nenhum endpoint Admin emite dado clínico cru" do
    ENDPOINTS.each do |path|
      get path
      body = response.body.to_s
      SENTINELS.each_value do |sentinel|
        assert_not_includes body, sentinel,
          "endpoint #{path} vazou sentinela #{sentinel} — quebra LGPD (§2.1, ADR 0011/0015)"
      end
    end
  end

  private

  def login!
    post "/session",
         params: { email_address: @user.email_address, password: "lgpd-password" }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_equal 201, response.status, "login falhou: #{response.body}"
  end

  def seed_sentinels!
    InboundMessage.create!(
      message_id: SecureRandom.uuid,
      from: "+5511999999999",
      kind: "text",
      raw: SENTINELS[:inbound_raw]
    )

    conv = Conversation.create!(phone: "+5511988888888", state: "consented")
    Consent.create!(
      conversation: conv,
      version: 1,
      policy_text_sha: "sha-test",
      channel: "whatsapp",
      given_at: 1.day.ago,
      evidence: SENTINELS[:consent_evid]
    )

    pd = ProtocolDefinition.create!(
      name: "triagem-respiratoria",
      version: 1,
      status: "active",
      definition: {
        "name" => "triagem-respiratoria",
        "version" => 1,
        "start_step_id" => "q1",
        "steps" => [ { "id" => "q1", "branches" => {} } ]
      }
    )
    Triagem.create!(
      conversation: conv,
      protocol_definition: pd,
      protocol_name: "triagem-respiratoria",
      status: "completed",
      tier: "low",
      priority: false,
      completed_at: Time.current,
      answers: { "q1" => SENTINELS[:triagem_answer] },
      outcome: { "scoring" => { "mode" => "weighted" } }
    )
  end
end
