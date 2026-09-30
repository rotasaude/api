require "rails_helper"

# F-14.6 (ADR 0025; spec 2026-09-30 §7) pelo fluxo HTTP de autoria: a marca
# `analytic` só vale em boolean/enum, e o portão do ciclo assinado (submeter e
# publicar) recusa o resto com o erro do schema. Rascunho é trabalho em curso
# (Protocols::SaveDraft não roda o portão): o editor mostra o erro pelo
# /authoring/protocols/gate, e o rascunho só não sai do lugar.
RSpec.describe "Marca analytic no ciclo de autoria (F-14.6)", type: :request do
  def json = JSON.parse(response.body)

  def enrolled_user(email:, role:)
    u = User.create!(email_address: email, password: "secret123")
    Mfa::Enroll.call(u)
    u.update!(otp_enabled: true)
    Membership.create!(user: u, role: role, granted_at: Time.current)
    u
  end

  let!(:author) { enrolled_user(email: "autora-#{SecureRandom.hex(3)}@example.org", role: "protocol_author") }
  let!(:publisher) { enrolled_user(email: "pub-#{SecureRandom.hex(3)}@example.org", role: "protocol_publisher") }

  def with_step(step)
    protocol_definition_hash(name: "arbo-flag", version: 1).tap do |definition|
      definition["steps"] = [ { "id" => "s1", "prompt" => "?", "branches" => {} }.merge(step) ]
    end
  end

  let(:integer_marked) { with_step("answer_type" => "integer", "analytic" => true) }
  let(:enum_without_options) { with_step("answer_type" => "enum", "analytic" => true) }

  it "gate do editor: integer marcado recusado com o caminho da pergunta" do
    sign_in_as(author)

    post "/authoring/protocols/gate", params: { definition: integer_marked }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["errors"]).to include(a_string_including("/steps/0/answer_type"))
  end

  it "rascunho grava; submeter recusa 422 invalid com o erro do schema e a versão fica em draft" do
    sign_in_as(author)
    post "/authoring/protocols/draft", params: { definition: integer_marked }, as: :json
    expect(response).to have_http_status(:ok)
    expect(json).to include("status" => "draft")

    post "/protocols/1/submit", params: { name: "arbo-flag" }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("invalid")
    expect(json["message"]).to include("/steps/0/answer_type")
    expect(ProtocolDefinition.find_by!(name: "arbo-flag", version: 1).status).to eq("draft")
  end

  # A regra "enum exige options" mora no schema (contracts protocols-v1.3.0).
  it "enum marcado sem options: submeter recusa pela regra de options" do
    Protocols::SaveDraft.call(definition: enum_without_options, by: author)
    sign_in_as(author)

    post "/protocols/1/submit", params: { name: "arbo-flag" }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("invalid")
    expect(json["message"]).to include("/steps/0")
  end

  # Conteúdo que chegou a in_review por fora (gravado direto no banco): a
  # publicação roda o portão de novo e recusa antes de contar assinaturas.
  it "publicar recusa 422 invalid com o erro do schema" do
    Protocols::SaveDraft.call(definition: integer_marked, by: author)
    ProtocolDefinition.find_by!(name: "arbo-flag", version: 1).update_columns(status: "in_review")
    sign_in_as(publisher).update!(mfa_verified_at: Time.current)

    post "/protocols/1/publish", params: { name: "arbo-flag" }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("invalid")
    expect(json["message"]).to include("/steps/0/answer_type")
    expect(ProtocolDefinition.find_by!(name: "arbo-flag", version: 1).status).to eq("in_review")
  end
end
