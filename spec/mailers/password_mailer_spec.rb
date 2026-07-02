require "rails_helper"

RSpec.describe PasswordMailer, type: :mailer do
  let(:user) { User.create!(email_address: "mailer-#{SecureRandom.hex(3)}@x.com", password: "secret123") }

  it "addresses the user and includes a ?reset= link, not the raw password" do
    mail = described_class.reset(user)
    expect(mail.to).to eq([user.email_address])
    expect(mail.subject).to be_present
    body = mail.body.encoded
    expect(body).to include("?reset=")
    expect(body).not_to include("secret123")
  end
end
