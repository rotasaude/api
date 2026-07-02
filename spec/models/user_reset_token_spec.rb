require "rails_helper"

RSpec.describe "User password_reset token (F-06.2)", type: :model do
  let(:user) { User.create!(email_address: "reset-#{SecureRandom.hex(3)}@x.com", password: "old-password-1") }

  it "round-trips a password_reset token" do
    token = user.generate_token_for(:password_reset)
    expect(User.find_by_token_for(:password_reset, token)).to eq(user)
  end

  it "invalidates the token once the password changes (single-use)" do
    token = user.generate_token_for(:password_reset)
    user.update!(password: "new-password-2")
    expect(User.find_by_token_for(:password_reset, token)).to be_nil
  end

  it "returns nil for a garbage token" do
    expect(User.find_by_token_for(:password_reset, "not-a-real-token")).to be_nil
  end
end
