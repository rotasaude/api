require "rails_helper"

RSpec.describe InvitationMailer, type: :mailer do
  let(:accept_url) { "http://novacidade.localhost:5175/dashboard/?invite=tok-123" }

  # R42: só valores simples — roda no worker, sem conexão de cidade.
  it "addresses the given e-mail and carries the given invitation link" do
    mail = described_class.invite(email_address: "prefeita@novacidade.gov.br", accept_url: accept_url)

    expect(mail.to).to eq([ "prefeita@novacidade.gov.br" ])
    expect(mail.subject).to be_present
    expect(mail.text_part.body.decoded).to include(accept_url)
    expect(mail.html_part.body.decoded).to include(accept_url)
  end
end
