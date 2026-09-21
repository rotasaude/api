require "rails_helper"

# Ciclo de vida do protocolo, assinado, na API da cidade (spec de assinaturas
# §4/§6/§8; Plano 2 "assinaturas — API da cidade", Task 3). Cobre o fluxo
# feliz completo com as regras reais dos commands (Plano 1), o step-up de MFA
# em todo ato que aprova ou põe em uso, os motivos de recusa 422 com a
# mensagem do próprio command, a autorização por papel, a reversão de
# emergência sobre a linha-base (Task 1) e a negação por padrão da sessão de
# operador (grant).
RSpec.describe "Protocol lifecycle", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  def json = JSON.parse(response.body)

  def enrolled_user(email:, role:)
    u = User.create!(email_address: email, password: "secret123")
    Mfa::Enroll.call(u)
    u.update!(otp_enabled: true)
    Membership.create!(user: u, role: role, granted_at: Time.current) if role
    u
  end

  # Autentica `user` (sessão real, cookie assinado — city_request_auth.rb) e
  # carimba mfa_verified_at recente, como MfaStepUp#require_step_up! exige,
  # sem passar por TOTP de verdade.
  def sign_in_stepped_up!(user)
    session = sign_in_as(user)
    session.update!(mfa_verified_at: Time.current)
    session
  end

  let!(:author)    { enrolled_user(email: "author@example.org", role: "protocol_author") }
  let!(:ana)       { enrolled_user(email: "ana@example.org", role: "protocol_reviewer") }
  let!(:bia)       { enrolled_user(email: "bia@example.org", role: "protocol_reviewer") }
  let!(:publisher) { enrolled_user(email: "pub@example.org", role: "protocol_publisher") }
  let!(:viewer)    { enrolled_user(email: "viewer@example.org", role: "viewer") }

  def save_draft!(name: "dengue", version: 1, by: author)
    Protocols::SaveDraft.call(definition: protocol_definition_hash(name: name, version: version), by: by)
  end

  describe "fluxo completo com as regras reais" do
    it "vai de draft a active pelo ciclo assinado (submit, sign, publish, sign, activate)" do
      save_draft!

      sign_in_as(author)
      post "/protocols/1/submit", params: { name: "dengue" }, as: :json
      expect(response).to have_http_status(:ok)
      expect(json).to eq("ok" => true, "protocol" => { "name" => "dengue", "version" => 1, "status" => "in_review" })
      expect(ProtocolDefinition.find_by(name: "dengue", version: 1).status).to eq("in_review")

      sign_in_stepped_up!(ana)
      post "/protocols/1/signatures", params: { name: "dengue", purpose: "publication" }, as: :json
      expect(response).to have_http_status(:ok)
      expect(json["ok"]).to be(true)
      expect(json["signature"]["purpose"]).to eq("publication")

      sign_in_stepped_up!(bia)
      post "/protocols/1/signatures", params: { name: "dengue", purpose: "publication" }, as: :json
      expect(response).to have_http_status(:ok)

      sign_in_stepped_up!(publisher)
      post "/protocols/1/publish", params: { name: "dengue" }, as: :json
      expect(response).to have_http_status(:ok)
      # PublicationsController#create preserva `id` ao lado do formato novo
      # `protocol` — é o que o dashboard consome hoje (ver relatório).
      expect(json["ok"]).to be(true)
      expect(json["id"]).to eq(ProtocolDefinition.find_by(name: "dengue", version: 1).id)
      expect(json["protocol"]).to eq("name" => "dengue", "version" => 1, "status" => "published")
      expect(ProtocolDefinition.find_by(name: "dengue", version: 1).status).to eq("published")

      sign_in_stepped_up!(ana)
      post "/protocols/1/signatures", params: { name: "dengue", purpose: "activation" }, as: :json
      expect(response).to have_http_status(:ok)

      sign_in_stepped_up!(bia)
      post "/protocols/1/signatures", params: { name: "dengue", purpose: "activation" }, as: :json
      expect(response).to have_http_status(:ok)

      sign_in_stepped_up!(publisher)
      post "/protocols/1/activate", params: { name: "dengue" }, as: :json
      expect(response).to have_http_status(:ok)
      expect(json).to eq("ok" => true, "protocol" => { "name" => "dengue", "version" => 1, "status" => "active" })
      expect(ProtocolDefinition.find_by(name: "dengue", version: 1).status).to eq("active")
    end
  end

  describe "step-up (MFA) obrigatório nos atos que aprovam ou põem em uso" do
    it "responde 401 mfa_required sem step-up recente, e nada muda no banco" do
      pd = ProtocolDefinition.create!(name: "dengue", version: 1, status: "in_review",
                                      definition: protocol_definition_hash)

      sign_in_as(ana)
      post "/protocols/1/signatures", params: { name: "dengue", purpose: "publication" }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "mfa_required")
      expect(ProtocolSignature.count).to eq(0)

      sign!(pd, purpose: "publication", by: ana)
      sign!(pd, purpose: "publication", by: bia)

      sign_in_as(publisher)
      post "/protocols/1/publish", params: { name: "dengue" }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "mfa_required")
      expect(pd.reload.status).to eq("in_review")

      pd.update!(status: "published")
      sign!(pd, purpose: "activation", by: ana)
      sign!(pd, purpose: "activation", by: bia)

      sign_in_as(publisher)
      post "/protocols/1/activate", params: { name: "dengue" }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "mfa_required")
      expect(pd.reload.status).to eq("published")

      sign_in_as(publisher)
      post "/protocols/1/retire", params: { name: "dengue" }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "mfa_required")
      expect(pd.reload.status).to eq("published")

      legacy = ProtocolDefinition.create!(name: "triagem-legado", version: 1, status: "active",
                                          definition: protocol_definition_hash(name: "triagem-legado"))
      legacy.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil)
      v2 = ProtocolDefinition.create!(name: "triagem-legado", version: 2, status: "published",
                                      definition: protocol_definition_hash(name: "triagem-legado", version: 2))
      sign!(v2, purpose: "activation", by: ana)
      sign!(v2, purpose: "activation", by: bia)
      sign_in_stepped_up!(publisher)
      post "/protocols/2/activate", params: { name: "triagem-legado" }, as: :json
      expect(response).to have_http_status(:ok)

      sign_in_as(publisher)
      post "/protocols/revert", params: { name: "triagem-legado", reason: "erro" }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "mfa_required")
      expect(ProtocolDefinition.find_by(name: "triagem-legado", version: 2).status).to eq("active")
    end

    it "enviar para revisão não exige step-up" do
      save_draft!
      sign_in_as(author)
      post "/protocols/1/submit", params: { name: "dengue" }, as: :json
      expect(response).to have_http_status(:ok)
    end
  end

  describe "regras de domínio aparecem como 422 com a mensagem do command" do
    it "publicar com uma assinatura de publicação: signatures_missing com a contagem" do
      pd = ProtocolDefinition.create!(name: "dengue", version: 1, status: "in_review",
                                      definition: protocol_definition_hash)
      sign!(pd, purpose: "publication", by: ana)

      sign_in_stepped_up!(publisher)
      post "/protocols/1/publish", params: { name: "dengue" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("signatures_missing")
      expect(json["message"]).to eq("falta 1 assinatura de publicação; revisores elegíveis na cidade: 2")
    end

    it "o autor tentando assinar a própria versão: contributor_cannot_sign" do
      pd = ProtocolDefinition.create!(name: "dengue", version: 1, status: "in_review",
                                      definition: protocol_definition_hash)
      ProtocolContribution.create!(protocol_definition: pd, actor_id: ana.id, actor_kind: "user",
                                   content_digest: pd.content_digest)

      sign_in_stepped_up!(ana)
      post "/protocols/1/signatures", params: { name: "dengue", purpose: "publication" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("contributor_cannot_sign")
    end

    it "ativar um rascunho: not_published" do
      ProtocolDefinition.create!(name: "dengue", version: 1, status: "draft", definition: protocol_definition_hash)

      sign_in_stepped_up!(publisher)
      post "/protocols/1/activate", params: { name: "dengue" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("not_published")
    end

    it "aposentar a versão active: active_in_city" do
      ProtocolDefinition.create!(name: "dengue", version: 1, status: "active", definition: protocol_definition_hash)

      sign_in_stepped_up!(publisher)
      post "/protocols/1/retire", params: { name: "dengue" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("active_in_city")
    end

    it "reverter sem motivo: reason_required" do
      sign_in_stepped_up!(publisher)
      post "/protocols/revert", params: { name: "dengue", reason: "  " }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("reason_required")
    end
  end

  describe "autorização" do
    it "assinar sem protocol_reviewer: 403 forbidden" do
      ProtocolDefinition.create!(name: "dengue", version: 1, status: "in_review", definition: protocol_definition_hash)

      sign_in_stepped_up!(viewer)
      post "/protocols/1/signatures", params: { name: "dengue", purpose: "publication" }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(json).to eq("error" => "forbidden")
    end

    it "versão inexistente, com step-up: 404" do
      sign_in_stepped_up!(publisher)
      post "/protocols/999/activate", params: { name: "dengue" }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "versão inexistente, sem step-up: 401 (a recusa não revela se a versão existe)" do
      sign_in_as(publisher)
      post "/protocols/999/activate", params: { name: "dengue" }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "mfa_required")
    end
  end

  describe "reversão de emergência sobre a linha-base (Task 1)" do
    it "volta para a versão anterior e registra o motivo na linha emergency_revert" do
      legacy = ProtocolDefinition.create!(name: "dengue", version: 1, status: "active", activated_at: 3.days.ago,
                                          definition: protocol_definition_hash)
      legacy.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil, created_at: 3.days.ago)

      v2 = ProtocolDefinition.create!(name: "dengue", version: 2, status: "published",
                                      definition: protocol_definition_hash(version: 2))
      sign!(v2, purpose: "activation", by: ana)
      sign!(v2, purpose: "activation", by: bia)
      sign_in_stepped_up!(publisher)
      post "/protocols/2/activate", params: { name: "dengue" }, as: :json
      expect(response).to have_http_status(:ok)

      sign_in_stepped_up!(publisher)
      post "/protocols/revert", params: { name: "dengue", reason: "v2 erra a prioridade" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(json).to eq("ok" => true, "protocol" => { "name" => "dengue", "version" => 1, "status" => "active" })
      expect(legacy.reload.status).to eq("active")
      expect(v2.reload.status).to eq("published")
      expect(legacy.activations.order(:created_at).last)
        .to have_attributes(kind: "emergency_revert", reason: "v2 erra a prioridade")
    end
  end

  describe "sessão de operador (grant) é só leitura" do
    it "responde 403 operator_read_only em cada endpoint novo" do
      operator = Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                                  otp_secret: ROTP::Base32.random, otp_enabled: true)
      ProtocolDefinition.create!(name: "dengue", version: 1, status: "in_review", definition: protocol_definition_hash)

      sign_in_operator_grant(operator)

      requests = [
        [ :post, "/protocols/1/submit", { name: "dengue" } ],
        [ :post, "/protocols/1/signatures", { name: "dengue", purpose: "publication" } ],
        [ :post, "/protocols/1/activate", { name: "dengue" } ],
        [ :post, "/protocols/1/retire", { name: "dengue" } ],
        [ :post, "/protocols/revert", { name: "dengue", reason: "x" } ]
      ]

      requests.each do |verb, path, params|
        send(verb, path, params: params, as: :json)
        expect(response).to have_http_status(:forbidden), "#{verb.upcase} #{path} respondeu #{response.status}"
        expect(json).to eq("error" => "operator_read_only"), "#{verb.upcase} #{path} respondeu #{response.body}"
      end
    end
  end

  describe "nenhum dado de cidadão nas respostas" do
    it "os corpos de sucesso não trazem phone, wa_id nem chaves além das documentadas" do
      ProtocolDefinition.create!(name: "dengue", version: 1, status: "in_review", definition: protocol_definition_hash)

      sign_in_stepped_up!(ana)
      post "/protocols/1/signatures", params: { name: "dengue", purpose: "publication" }, as: :json

      expect(response.body).not_to match(/phone|wa_id/i)
      expect(json.keys).to match_array(%w[ok protocol signature])
      expect(json["signature"].keys).to match_array(%w[purpose created_at])
    end
  end
end
