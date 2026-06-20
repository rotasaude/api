require "rails_helper"

# use_transactional_tests = false: Platform.audit usa connected_to(role: :admin)
# para escrever via BYPASSRLS. Sob transactional fixtures, Rails força todas as
# escritas no mesmo physical connection (rota_app) para o rollback funcionar,
# anulando o connected_to. Sem transactional fixtures, o connected_to retorna a
# conexão admin de verdade e o INSERT bypassa RLS.
RSpec.describe Platform do
  self.use_transactional_tests = false

  before do
    ApplicationRecord.connected_to(role: :admin) do
      ApplicationRecord.connection.execute("DELETE FROM domain_events")
      ApplicationRecord.connection.execute("DELETE FROM conversations")
      ApplicationRecord.connection.execute("DELETE FROM users")
      ApplicationRecord.connection.execute("DELETE FROM municipalities")
    end
    Current.reset
  end

  after do
    ApplicationRecord.connected_to(role: :admin) do
      ApplicationRecord.connection.execute("DELETE FROM domain_events")
      ApplicationRecord.connection.execute("DELETE FROM conversations")
      ApplicationRecord.connection.execute("DELETE FROM users")
      ApplicationRecord.connection.execute("DELETE FROM municipalities")
    end
    Current.reset
  end

  it "grava domain_events com municipality_id NULL" do
    Platform.audit("user.logged_in", user_id: SecureRandom.uuid)
    ApplicationRecord.connected_to(role: :admin) do
      ev = DomainEvent.order(occurred_at: :desc).first
      expect(ev.name).to eq("user.logged_in")
      expect(ev.municipality_id).to be_nil
    end
  end

  it "linha platform-scope NÃO aparece sob tenant" do
    Platform.audit("user.logged_in", user_id: SecureRandom.uuid)
    muni = ApplicationRecord.connected_to(role: :admin) { Municipality.create!(name: "Test", slug: "test-muni") }
    ApplicationRecord.transaction do
      Current.municipality_id = muni.id
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", muni.id])
      )
      expect(DomainEvent.where(name: "user.logged_in").count).to eq(0)
    end
  end
end
