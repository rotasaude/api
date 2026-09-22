require "rails_helper"

# A1 do fix wave da fatia 2 (Equipe): a lista de equipe não pode contar gente
# desativada. `DeactivateUser` não revoga memberships — só marca
# `users.deactivated_at` —, então `Membership.active` sozinho ainda inclui a
# membership de um usuário desativado; a tela contaria um revisor a mais do
# que `Protocols::Signatures.active_reviewer_ids` (que já exclui desativado).
RSpec.describe "Setup list_memberships", type: :request do
  def json = JSON.parse(response.body)

  let!(:admin) do
    User.create!(email_address: "admin-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "municipal_admin", granted_at: Time.current)
    end
  end
  let!(:active_reviewer) do
    User.create!(email_address: "ativa-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "protocol_reviewer", granted_at: Time.current)
    end
  end
  let!(:deactivated_reviewer) do
    User.create!(email_address: "desativada-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "protocol_reviewer", granted_at: Time.current)
      u.update!(deactivated_at: Time.current)
    end
  end

  it "não lista a membership de um usuário desativado, e lista a de um usuário ativo" do
    sign_in_as(admin)

    get "/setup/memberships", as: :json

    expect(response).to have_http_status(:ok)
    user_ids = json["data"].map { |row| row["user"]["id"] }
    expect(user_ids).to include(admin.id, active_reviewer.id)
    expect(user_ids).not_to include(deactivated_reviewer.id)
  end
end
