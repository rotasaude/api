require "rails_helper"

RSpec.describe "Passwords (F-06.2)", type: :request do
  include ActiveJob::TestHelper

  def make_user(active: true, password: "old-password-1")
    u = User.create!(email_address: "u-#{SecureRandom.hex(3)}@x.com", password: password)
    u.update!(deactivated_at: Time.current) unless active
    u
  end

  describe "POST /passwords (request reset)" do
    it "enqueues the reset mail for an active user and returns 204" do
      user = make_user
      expect {
        post "/passwords", params: { email_address: user.email_address }
      }.to have_enqueued_mail(PasswordMailer, :reset)
      expect(response).to have_http_status(:no_content)
    end

    # R42: ActionMailer::MailDeliveryJob is not a CityScopedJob — a worker runs
    # it with no city connection (CityRecord's :bootstrap shard, no tables), so
    # a GlobalID of a User cannot be deserialized there. The controller must
    # hand the mailer plain values built inside the city request, with the link
    # on the CITY host (the reset form resolves the city by subdomain).
    it "delivers the enqueued mail from a worker with no city connection, linking to the city host" do
      user = make_user
      post "/passwords", params: { email_address: user.email_address }
      expect(response).to have_http_status(:no_content)

      Current.reset
      expect {
        CityRecord.connected_to(shard: :bootstrap) { perform_enqueued_jobs }
      }.to change { ActionMailer::Base.deliveries.size }.by(1)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([user.email_address])

      link = URI.parse(mail.text_part.body.decoded[%r{https?://[^\s"<]+}])
      expect(link.host).to eq(test_city_host)
      token = Rack::Utils.parse_query(link.query)["reset"]
      expect(token).to be_present
      expect(CityConnection.with(TEST_CITY_A) { User.find_by_token_for(:password_reset, token) }).to eq(user)
    end

    it "does not enumerate: unknown email returns 204 with no mail" do
      expect {
        post "/passwords", params: { email_address: "nobody@nowhere.com" }
      }.not_to have_enqueued_mail(PasswordMailer, :reset)
      expect(response).to have_http_status(:no_content)
    end

    it "does not email a deactivated user (still 204)" do
      user = make_user(active: false)
      expect {
        post "/passwords", params: { email_address: user.email_address }
      }.not_to have_enqueued_mail(PasswordMailer, :reset)
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "PUT /passwords/:token (perform reset)" do
    it "resets the password, destroys sessions, and returns 204" do
      user = make_user
      session = user.sessions.create!(user_agent: "rspec", ip_address: "127.0.0.1")
      token = user.generate_token_for(:password_reset)

      put "/passwords/#{token}", params: { password: "new-password-2", password_confirmation: "new-password-2" }
      expect(response).to have_http_status(:no_content)

      expect(Authenticator.password(email: user.email_address, password: "new-password-2")).to eq(user)
      expect(Authenticator.password(email: user.email_address, password: "old-password-1")).to be_nil
      expect(Session.exists?(session.id)).to be(false)
    end

    it "returns 422 for an invalid token" do
      put "/passwords/garbage-token", params: { password: "whatever-123", password_confirmation: "whatever-123" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("invalid_token")
    end

    it "returns 422 for a mismatched/blank password" do
      user = make_user
      token = user.generate_token_for(:password_reset)
      put "/passwords/#{token}", params: { password: "a", password_confirmation: "b" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)).to have_key("errors")
    end

    it "is single-use: replaying a consumed token returns 422" do
      user = make_user
      token = user.generate_token_for(:password_reset)
      put "/passwords/#{token}", params: { password: "new-password-2", password_confirmation: "new-password-2" }
      expect(response).to have_http_status(:no_content)

      put "/passwords/#{token}", params: { password: "again-password-3", password_confirmation: "again-password-3" }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects a reset for a deactivated user (indistinguishable from an invalid token)" do
      user = make_user
      token = user.generate_token_for(:password_reset)
      user.update!(deactivated_at: Time.current)

      put "/passwords/#{token}", params: { password: "new-password-2", password_confirmation: "new-password-2" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("invalid_token")
      # a senha NÃO mudou:
      expect(Authenticator.password(email: user.email_address, password: "old-password-1")).to be_nil # (desativado nem loga)
      expect(user.reload.authenticate("old-password-1")).to be_truthy
    end
  end
end
