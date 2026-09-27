require "rails_helper"

# F-06.10: desativar é end-dating (deactivated_at), nunca DELETE, e derruba
# todas as sessões do usuário na mesma transação.
RSpec.describe User, "#deactivate!", type: :model do
  let!(:user) { User.create!(email_address: "d-#{SecureRandom.hex(3)}@x.com", password: "secret123") }
  let!(:other) { User.create!(email_address: "o-#{SecureRandom.hex(3)}@x.com", password: "secret123") }

  it "marca deactivated_at e apaga as sessões do usuário, sem tocar nas dos outros" do
    user.sessions.create!(user_agent: "a", ip_address: "127.0.0.1")
    user.sessions.create!(user_agent: "b", ip_address: "127.0.0.1")
    kept = other.sessions.create!(user_agent: "c", ip_address: "127.0.0.1")

    user.deactivate!

    expect(user.reload.deactivated_at).to be_present
    expect(user).not_to be_active
    expect(Session.where(user_id: user.id)).to be_empty
    expect(Session.exists?(kept.id)).to be(true)
  end
end
