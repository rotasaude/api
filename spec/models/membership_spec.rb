# apps/api/spec/models/membership_spec.rb
require "rails_helper"

RSpec.describe Membership do
  let!(:user) { User.create!(email_address: "m@example.org", password: "secret123") }

  # Plano 3: grant de operador — Membership não carrega mais papel/coluna de
  # operador de plataforma. `ck_memberships_role` (db/city_schema.rb) só
  # aceita os 4 papéis locais (Membership::ROLES); não existe `municipality`
  # nem `platform_operator` para construir este cenário. O invariante que
  # essas duas asserções protegiam ("operador não é amarrado a uma cidade")
  # agora vive em User#operator? (app/models/user.rb:44), hardcoded `false` —
  # nenhum usuário de cidade pode virar operador de plataforma; o operador
  # real é `Operator`, na plataforma (Plano 3).
  it "operator membership tem municipality_id nulo" do
    skip "Plano 3: grant de operador — Membership não tem mais papel/coluna de operador " \
         "(ck_memberships_role só aceita os 4 papéis locais); o invariante vive agora em " \
         "User#operator? (hardcoded false)"
  end

  it "operator com municipality_id setado é inválido" do
    skip "Plano 3: grant de operador — Membership não tem mais coluna municipality nem papel " \
         "platform_operator (ck_memberships_role); não há mais como construir este cenário"
  end

  it "índice único parcial bloqueia membership duplicado ativo" do
    Membership.create!(user: user, role: "municipal_admin", granted_at: Time.current)
    expect {
      Membership.create!(user: user, role: "municipal_admin", granted_at: Time.current)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "revogar permite reconceder linha nova" do
    m = Membership.create!(user: user, role: "viewer", granted_at: Time.current)
    m.revoke!
    expect {
      Membership.create!(user: user, role: "viewer", granted_at: Time.current)
    }.not_to raise_error
  end
end
