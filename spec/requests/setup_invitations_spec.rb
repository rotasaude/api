require "rails_helper"

# F-06.9: POST /setup/invitations cria o convite E manda o e-mail com o link de
# aceite. Antes só gravava o convite e publicava user.invited — ninguém recebia.
RSpec.describe "POST /setup/invitations", type: :request do
  include ActiveJob::TestHelper

  def json = JSON.parse(response.body)

  let!(:admin) do
    User.create!(email_address: "adm-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "municipal_admin", granted_at: Time.current)
    end
  end

  before { sign_in_as(admin) }

  def invite!(email: "novo@example.org", role: "viewer")
    post "/setup/invitations", params: { email: email, role: role }, as: :json
  end

  it "enfileira o e-mail do convite com o link de aceite do dashboard da cidade" do
    expect { invite! }.to have_enqueued_mail(MemberInvitationMailer, :invite)

    expect(response).to have_http_status(:created)
    inv = Invitation.find(json["id"])
    job = enqueued_jobs.find { |j| j["job_class"] == "CityMailDeliveryJob" }
    kwargs = job["arguments"].last["args"].first
    expect(kwargs).to include("email_address" => "novo@example.org",
                              "accept_url" => CityDashboardUrl.invitation(City.find_by!(slug: TEST_CITY_A.slug),
                                                                          token: inv.token))
  end

  it "não loga o token nem o e-mail ao enfileirar" do
    log_output = StringIO.new
    original_logger = ActiveJob::Base.logger
    ActiveJob::Base.logger = ActiveSupport::Logger.new(log_output)
    begin
      invite!(email: "segredo@example.org")
    ensure
      ActiveJob::Base.logger = original_logger
    end

    token = Invitation.find_by!(email: "segredo@example.org").token
    expect(log_output.string).not_to include(token)
    expect(log_output.string).not_to include("segredo@example.org")
  end

  it "e-mail de usuário que já está na cidade: 422 already_member, sem e-mail" do
    User.create!(email_address: "ja@example.org", password: "secret123")

    expect { invite!(email: "ja@example.org") }.not_to have_enqueued_mail(MemberInvitationMailer, :invite)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["error"]).to eq("already_member")
  end

  it "convite pendente para o mesmo e-mail: vence o anterior, cria outro e manda o link novo" do
    invite!(email: "pend@example.org")
    first = Invitation.find(json["id"])

    expect { invite!(email: "pend@example.org") }.to have_enqueued_mail(MemberInvitationMailer, :invite)

    expect(response).to have_http_status(:created)
    expect(first.reload.expired?).to be(true)
    expect(Invitation.pending.where(email: "pend@example.org").sole.id).to eq(json["id"])
  end

  it "o e-mail leva o link de aceite nas duas partes" do
    mail = MemberInvitationMailer.invite(email_address: "novo@example.org", accept_url: "https://x.example/?invite=t0k")

    expect(mail.to).to eq([ "novo@example.org" ])
    expect(mail.html_part.body.to_s).to include("https://x.example/?invite=t0k")
    expect(mail.text_part.body.to_s).to include("https://x.example/?invite=t0k")
  end
end
