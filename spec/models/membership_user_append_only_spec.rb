require "rails_helper"

# Fechamento do módulo 06 (ADR-0012): usuário e membership nunca são apagados —
# desativar e revogar são end-dating. Membership só muda para receber a
# revogação, uma vez; papel, usuário, quem concedeu e quando nunca mudam. O
# trigger fecha o caminho que o modelo não fecha (update_column, delete_all,
# psql com o papel de runtime) — não o DONO da tabela, ver db/city_triggers.sql.
RSpec.describe "users e memberships append-only" do
  def attempt
    ApplicationRecord.transaction(requires_new: true) { yield }
  end

  let!(:granter) { User.create!(email_address: "g-#{SecureRandom.hex(3)}@x.com", password: "secret123") }
  let!(:user) { User.create!(email_address: "u-#{SecureRandom.hex(3)}@x.com", password: "secret123") }
  let!(:membership) { Membership.create!(user: user, role: "viewer", granted_by: granter, granted_at: 1.day.ago) }

  describe "users" do
    it "recusa DELETE, mesmo por delete_all" do
      expect { attempt { User.where(id: granter.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /users is append-only: DELETE refused/)
      expect(User.exists?(granter.id)).to be(true)
    end

    it "continua aceitando UPDATE (senha, MFA, desativação)" do
      user.deactivate!
      expect(user.reload.deactivated_at).to be_present
    end
  end

  describe "memberships" do
    it "recusa DELETE, mesmo por delete_all" do
      expect { attempt { Membership.where(id: membership.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /memberships is append-only: DELETE refused/)
    end

    it "aceita revogar uma vez (revoke! e RevokeMembership fazem isso)" do
      membership.revoke!(by: granter)
      expect(membership.reload.revoked_at).to be_present
    end

    it "recusa mudar a revogação depois de feita, mesmo por update_column" do
      membership.revoke!
      expect { attempt { membership.update_column(:revoked_at, 1.year.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /memberships: already revoked/)
      expect { attempt { Membership.where(id: membership.id).update_all(revoked_at: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /memberships: already revoked/)
    end

    it "recusa mudar papel, usuário, concessor ou data de concessão, mesmo por update_column/update_all" do
      other = User.create!(email_address: "o-#{SecureRandom.hex(3)}@x.com", password: "secret123")
      { role: "municipal_admin", user_id: other.id, granted_by_id: other.id, granted_at: 2.days.ago }.each do |col, value|
        expect { attempt { membership.update_column(col, value) } }
          .to raise_error(ActiveRecord::StatementInvalid, /memberships: only revoked_at may change/), col.to_s
      end
      expect { attempt { Membership.where(id: membership.id).update_all(role: "municipal_admin", revoked_at: Time.current) } }
        .to raise_error(ActiveRecord::StatementInvalid, /memberships: only revoked_at may change/)
      expect(membership.reload.role).to eq("viewer")
    end
  end
end
