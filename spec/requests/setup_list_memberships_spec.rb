require "rails_helper"

# A1 do fix wave da fatia 2 (Equipe): a lista de equipe não pode contar gente
# desativada. Até o fechamento do módulo 06, `DeactivateUser` não revogava
# memberships — só marcava `users.deactivated_at` —, e usuários desativados
# antes disso seguem com memberships ativas: `Membership.active` sozinho ainda
# as inclui, e a tela contaria um revisor a mais do que
# `Protocols::Signatures.active_reviewer_ids` (que já exclui desativado).
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

  it "linhas de health_professional trazem professional_status; outras não" do
    novato = staff_with("novato@cidade.gov.br", "health_professional")
    sign_in_as(admin)
    get "/setup/memberships"
    rows = JSON.parse(response.body)["data"]
    pro_row = rows.find { |r| r["user"]["id"] == novato.id }
    expect(pro_row["professional_status"]).to eq("missing_profile")
    expect(rows.find { |r| r["role"] == "municipal_admin" }).not_to have_key("professional_status")
  end
end
