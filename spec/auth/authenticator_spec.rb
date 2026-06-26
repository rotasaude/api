require "rails_helper"

RSpec.describe Authenticator do
  let!(:user) { User.create!(email_address: "alice@example.org", password: "secretpass") }

  it "retorna o user com senha certa" do
    expect(Authenticator.password(email: "alice@example.org", password: "secretpass")).to eq(user)
  end

  it "case-insensitive no email" do
    expect(Authenticator.password(email: "ALICE@Example.org", password: "secretpass")).to eq(user)
  end

  it "nil com senha errada" do
    expect(Authenticator.password(email: "alice@example.org", password: "wrong")).to be_nil
  end

  it "nil para usuário desativado" do
    user.update!(deactivated_at: Time.current)
    expect(Authenticator.password(email: "alice@example.org", password: "secretpass")).to be_nil
  end
end
