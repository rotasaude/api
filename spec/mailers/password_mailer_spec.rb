require "rails_helper"

RSpec.describe PasswordMailer, type: :mailer do
  let(:reset_url) { "http://testcitya.rotasaude.app/dashboard/?reset=tok-123" }

  # R42: the mailer takes plain values only — it never loads a record, so it can
  # run on a worker with no city connection.
  it "addresses the given e-mail and carries the given reset link" do
    mail = described_class.reset(email_address: "mailer@x.com", reset_url: reset_url)
    expect(mail.to).to eq(["mailer@x.com"])
    expect(mail.subject).to be_present
    expect(mail.text_part.body.decoded).to include(reset_url)
    expect(mail.html_part.body.decoded).to include(reset_url)
  end
end
