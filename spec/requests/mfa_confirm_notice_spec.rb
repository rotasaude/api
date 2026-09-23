require "rails_helper"

# Spec do aviso (2026-09-23-authenticator-change-notice §6): a confirmação que
# promove o pendente avisa o dono da conta. Recusa não avisa, e uma falha no
# envio não desfaz nem derruba a promoção.
RSpec.describe "MFA confirm notice", type: :request do
  include ActiveJob::TestHelper

  def json = JSON.parse(response.body)
  def deliveries = ActionMailer::Base.deliveries

  let!(:user) { User.create!(email_address: "dan-#{SecureRandom.hex(3)}@example.org", password: "secret123") }

  before { deliveries.clear }

  def enroll!(stepped_up: false)
    session = sign_in_as(user)
    session.update!(mfa_verified_at: Time.current) if stepped_up
    post "/mfa/enroll", as: :json
    expect(response).to have_http_status(:ok)
  end

  def pending_code = ROTP::TOTP.new(user.reload.otp_pending_secret).now

  def confirm!(code: pending_code)
    perform_enqueued_jobs { post "/mfa/confirm", params: { code: code }, as: :json }
  end

  it "primeiro cadastro: um aviso, com o assunto de cadastro, para o dono da conta" do
    enroll!

    confirm!

    expect(response).to have_http_status(:ok)
    expect(deliveries.size).to eq(1)
    expect(deliveries.first.to).to eq([ user.email_address ])
    expect(deliveries.first.subject).to eq("[rota-saúde] Autenticador cadastrado")
  end

  it "troca: assunto de troca" do
    Mfa::Enroll.call(user)
    user.update!(otp_enabled: true)
    enroll!(stepped_up: true)

    confirm!

    expect(deliveries.size).to eq(1)
    expect(deliveries.first.subject).to eq("[rota-saúde] Autenticador trocado")
  end

  it "o corpo leva o IP da requisição e o nome da cidade" do
    enroll!

    confirm!

    # O nome vem do catálogo, não de Current: Current é por requisição e já
    # foi zerado quando o exemplo chega aqui.
    body = deliveries.first.text_part.body.decoded
    expect(body).to include(City.find_by!(slug: TEST_CITY_A.slug).name)
    expect(body).to include("127.0.0.1")
  end

  it "recusa não avisa ninguém" do
    enroll!

    confirm!(code: "000000")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(deliveries).to be_empty
  end

  it "sem pendente: recusa e nenhum aviso" do
    sign_in_as(user)

    perform_enqueued_jobs { post "/mfa/confirm", params: { code: "123456" }, as: :json }

    expect(json).to eq("error" => "no_pending_enrollment")
    expect(deliveries).to be_empty
  end

  it "falha ao enfileirar não derruba a confirmação nem desfaz a promoção" do
    enroll!
    allow(SecurityMailer).to receive(:authenticator_changed).and_raise(StandardError, "fila fora do ar")

    confirm!

    expect(response).to have_http_status(:ok)
    expect(user.reload.mfa_enrolled?).to be(true)
    expect(user.otp_pending_secret).to be_nil
  end

  it "avisa uma vez por confirmação, não uma por tentativa" do
    enroll!
    confirm!(code: "000000")
    deliveries.clear

    confirm!

    expect(deliveries.size).to eq(1)
  end
end
