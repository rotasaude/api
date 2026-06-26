require "test_helper"

# Smoke test: cada endpoint do namespace Admin:: deve:
#   1. exigir auth (401 sem sessão)
#   2. responder 200 com sessão válida (após POST /session)
#   3. devolver o envelope { data:, as_of: }
class Admin::Api::SmokeTest < ActionDispatch::IntegrationTest
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
      email_address: "smoke-#{SecureRandom.hex(4)}@test.local",
      password: "smoke-password"
    )
  end

  test "todos os endpoints exigem autenticação" do
    ENDPOINTS.each do |path|
      get path
      assert_equal 401, response.status, "esperava 401 sem auth em #{path}"
    end
  end

  test "todos os endpoints devolvem envelope { data, as_of } com sessão válida" do
    login!
    ENDPOINTS.each do |path|
      get path
      assert_equal 200, response.status, "esperava 200 em #{path}: #{response.body}"
      json = JSON.parse(response.body)
      assert json.key?("data"),  "#{path} sem chave :data"
      assert json.key?("as_of"), "#{path} sem chave :as_of"
    end
  end

  test "nenhuma rota POST/PATCH/DELETE existe no namespace Admin::" do
    write_routes = Rails.application.routes.routes.select do |r|
      r.path.spec.to_s.start_with?("/admin/api") &&
        %w[POST PATCH PUT DELETE].include?(r.verb)
    end
    assert_empty write_routes,
      "Fase 1 é read-only: nenhuma rota de escrita em /admin/api (critério §10). Encontradas: #{write_routes.map(&:path)}"
  end

  private

  def login!
    post "/session",
         params: { email_address: @user.email_address, password: "smoke-password" }.to_json,
         headers: { "Content-Type" => "application/json" }
    assert_equal 201, response.status, "login falhou: #{response.body}"
  end
end
