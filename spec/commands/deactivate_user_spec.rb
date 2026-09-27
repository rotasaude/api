require "rails_helper"

# F-06.10: desativar também revoga os papéis ativos do usuário, pelo caminho
# de sempre (RevokeMembership, que publica membership.revoked), na mesma
# transação da desativação. Reativar fica fora (não existe).
RSpec.describe DeactivateUser do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let!(:admin) { User.create!(email_address: "adm-#{SecureRandom.hex(3)}@x.com", password: "secret123") }
  let!(:user) { User.create!(email_address: "u-#{SecureRandom.hex(3)}@x.com", password: "secret123") }
  let!(:viewer) { Membership.create!(user: user, role: "viewer", granted_at: 2.days.ago) }
  let!(:reviewer) { Membership.create!(user: user, role: "protocol_reviewer", granted_at: 2.days.ago) }
  let!(:old) { Membership.create!(user: user, role: "protocol_author", granted_at: 3.days.ago, revoked_at: 1.day.ago) }

  it "revoga cada membership ativa e publica membership.revoked para cada uma" do
    result = described_class.call(user_id: user.id, by: admin)

    expect(result.ok?).to be(true)
    expect(user.memberships.active).to be_empty
    events = DomainEvent.where(name: "membership.revoked").map(&:payload)
    expect(events).to contain_exactly(
      include("user_id" => user.id, "role" => "viewer", "by" => admin.id),
      include("user_id" => user.id, "role" => "protocol_reviewer", "by" => admin.id)
    )
    expect(old.reload.revoked_at).to be_within(1.second).of(1.day.ago)
  end

  it "é uma transação só: se a revogação falhar, o usuário continua ativo e com os papéis" do
    allow(RevokeMembership).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "falhou")

    expect { described_class.call(user_id: user.id, by: admin) }.to raise_error(ActiveRecord::StatementInvalid)

    expect(user.reload.deactivated_at).to be_nil
    expect(user.memberships.active.count).to eq(2)
  end
end
