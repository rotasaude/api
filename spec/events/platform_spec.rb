require "rails_helper"

RSpec.describe Platform do
  after { Current.reset }

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
    muni = create(:municipality)
    ApplicationRecord.transaction do
      Current.municipality_id = muni.id
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", muni.id])
      )
      expect(DomainEvent.where(name: "user.logged_in").count).to eq(0)
    end
  end
end
