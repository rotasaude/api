require "rails_helper"

# ADR 0026: pedido de exclusão do cadastro no balcão, confirmado por outra pessoa.
RSpec.describe "Erasure requests", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let!(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:verifier) { user_with("atendente@cidade.gov.br", "citizen_verifier") }
  let(:admin) { user_with("admin@cidade.gov.br", "municipal_admin") }
  let(:viewer) { user_with("leitura@cidade.gov.br", "viewer") }
  def body = JSON.parse(response.body)

  def user_with(email, *roles)
    User.create!(email_address: email, password: "senha-segura-123").tap do |u|
      Mfa::Enroll.call(u) # step-up só vale para quem tem TOTP ativo
      u.update!(otp_enabled: true)
      roles.each { |r| Membership.create!(user: u, role: r, granted_at: Time.current) }
    end
  end

  def sign_in_stepped_up(user) = sign_in_as(user).update!(mfa_verified_at: Time.current)

  def reject!(req)
    Citizens::RejectErasure.call(request: req, reason: "motivo suficiente", by: user_with("outro@cidade.gov.br", "municipal_admin"))
  end

  def request_erasure!(by: verifier)
    Citizens::RequestErasure.call(cpf: "52998224725", document_checked: true, by: by).payload[:request]
  end

  describe "papel errado" do
    it "devolve 403 nas quatro rotas" do
      pending_request = request_erasure!
      sign_in_stepped_up(viewer)

      json_post "/attendance/erasure_requests", cpf: "52998224725", document_checked: true
      expect(response).to have_http_status(:forbidden)
      get "/attendance/erasure_requests"
      expect(response).to have_http_status(:forbidden)
      json_post "/attendance/erasure_requests/#{pending_request.id}/confirm"
      expect(response).to have_http_status(:forbidden)
      json_post "/attendance/erasure_requests/#{pending_request.id}/reject", reason: "motivo suficiente"
      expect(response).to have_http_status(:forbidden)
      expect(pending_request.reload.status).to eq("pending")
    end

    it "não deixa o admin criar nem o verificador listar, confirmar ou rejeitar" do
      pending_request = request_erasure!
      sign_in_stepped_up(verifier)
      get "/attendance/erasure_requests"
      expect(response).to have_http_status(:forbidden)
      json_post "/attendance/erasure_requests/#{pending_request.id}/confirm"
      expect(response).to have_http_status(:forbidden)
      json_post "/attendance/erasure_requests/#{pending_request.id}/reject", reason: "motivo suficiente"
      expect(response).to have_http_status(:forbidden)

      sign_in_stepped_up(admin)
      json_post "/attendance/erasure_requests", cpf: "52998224725", document_checked: true
      expect(response).to have_http_status(:forbidden)
    end

    it "não deixa sessão de operador (grant, só leitura) passar" do
      operator = Operator.create!(email_address: "op@rotasaude.app", password: "s3nha-forte-1",
                                  otp_secret: ROTP::Base32.random, otp_enabled: true)
      pending_request = request_erasure!
      sign_in_operator_grant(operator)

      json_post "/attendance/erasure_requests", cpf: "52998224725", document_checked: true
      expect(response.status).to be_in([ 401, 403 ])
      json_post "/attendance/erasure_requests/#{pending_request.id}/confirm"
      expect(response.status).to be_in([ 401, 403 ])
      expect(pending_request.reload.status).to eq("pending")
    end
  end

  describe "POST /attendance/erasure_requests" do
    it "verificador cria o pedido pendente" do
      sign_in_as(verifier)
      json_post "/attendance/erasure_requests", cpf: "529.982.247-25", document_checked: true
      expect(response).to have_http_status(:created)
      expect(body["request"]).to include("status" => "pending")
      expect(body.to_s).not_to include("52998224725")
    end

    it "traduz as recusas do comando" do
      sign_in_as(verifier)
      json_post "/attendance/erasure_requests", cpf: "52998224725", document_checked: false
      expect([ response.status, body["error"] ]).to eq([ 422, "document_check_required" ])
      json_post "/attendance/erasure_requests", cpf: "123", document_checked: true
      expect([ response.status, body["error"] ]).to eq([ 422, "invalid_cpf" ])
      json_post "/attendance/erasure_requests", cpf: "11144477735", document_checked: true
      expect([ response.status, body["error"] ]).to eq([ 404, "citizen_not_found" ])
      json_post "/attendance/erasure_requests", cpf: "52998224725", document_checked: true
      json_post "/attendance/erasure_requests", cpf: "52998224725", document_checked: true
      expect([ response.status, body["error"] ]).to eq([ 409, "already_pending" ])
    end
  end

  describe "GET /attendance/erasure_requests" do
    it "lista só pendentes, sem CPF inteiro, com telefone mascarado" do
      request_erasure!
      sign_in_as(admin)
      get "/attendance/erasure_requests"
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("52998224725")
      expect(response.body).not_to include("998765432")
      row = body["requests"].sole
      expect(row).to include("requested_by" => "atendente@cidade.gov.br", "pairs" => 1,
                             "phone_masked" => "(**) *****-5432")
    end

    it "não lista o que já foi decidido" do
      reject!(request_erasure!)
      sign_in_as(admin)
      get "/attendance/erasure_requests"
      expect(body["requests"]).to eq([])
    end
  end

  describe "POST /attendance/erasure_requests/:id/confirm" do
    it "sem step-up: 401 mfa_required e o cidadão continua com CPF" do
      pending_request = request_erasure!
      sign_in_as(admin)
      json_post "/attendance/erasure_requests/#{pending_request.id}/confirm"
      expect([ response.status, body["error"] ]).to eq([ 401, "mfa_required" ])
      expect(citizen.reload.cpf).to eq("52998224725")
      expect(pending_request.reload.status).to eq("pending")
    end

    it "com step-up: confirma e apaga o cadastro" do
      pending_request = request_erasure!
      sign_in_stepped_up(admin)
      json_post "/attendance/erasure_requests/#{pending_request.id}/confirm"
      expect(response).to have_http_status(:ok)
      expect(body["request"]).to include("status" => "confirmed")
      expect(citizen.reload.cpf).not_to eq("52998224725")
    end

    it "quem pediu não confirma o próprio pedido: 403 own_request" do
      both = user_with("dupla@cidade.gov.br", "citizen_verifier", "municipal_admin")
      pending_request = request_erasure!(by: both)
      sign_in_stepped_up(both)
      json_post "/attendance/erasure_requests/#{pending_request.id}/confirm"
      expect([ response.status, body["error"] ]).to eq([ 403, "own_request" ])
      expect(citizen.reload.cpf).to eq("52998224725")
    end

    it "pedido já decidido: 409 not_pending; inexistente: 404" do
      pending_request = request_erasure!
      reject!(pending_request)
      sign_in_stepped_up(admin)
      json_post "/attendance/erasure_requests/#{pending_request.id}/confirm"
      expect([ response.status, body["error"] ]).to eq([ 409, "not_pending" ])
      json_post "/attendance/erasure_requests/0/confirm"
      expect(response).to have_http_status(:not_found)
    end

    it "deadlock no comando: 409 try_again" do
      pending_request = request_erasure!
      sign_in_stepped_up(admin)
      allow(Citizens::Erase).to receive(:call).and_raise(ActiveRecord::Deadlocked)
      json_post "/attendance/erasure_requests/#{pending_request.id}/confirm"
      expect([ response.status, body["error"] ]).to eq([ 409, "try_again" ])
    end
  end

  describe "POST /attendance/erasure_requests/:id/reject" do
    it "rejeita com motivo e deixa o cadastro intacto" do
      pending_request = request_erasure!
      sign_in_as(admin)
      json_post "/attendance/erasure_requests/#{pending_request.id}/reject", reason: "pedido feito por engano"
      expect(response).to have_http_status(:ok)
      expect(body["request"]).to include("status" => "rejected")
      expect(citizen.reload.cpf).to eq("52998224725")
    end

    it "motivo curto: 422; já decidido: 409; inexistente: 404" do
      pending_request = request_erasure!
      sign_in_as(admin)
      json_post "/attendance/erasure_requests/#{pending_request.id}/reject", reason: "x"
      expect([ response.status, body["error"] ]).to eq([ 422, "reason_too_short" ])
      reject!(pending_request)
      json_post "/attendance/erasure_requests/#{pending_request.id}/reject", reason: "motivo suficiente"
      expect([ response.status, body["error"] ]).to eq([ 409, "not_pending" ])
      json_post "/attendance/erasure_requests/0/reject", reason: "motivo suficiente"
      expect(response).to have_http_status(:not_found)
    end
  end
end
