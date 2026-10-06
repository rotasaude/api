require "rails_helper"
require Rails.root.join("db/city_migrate/20261005300001_add_suggestion_only_to_triage_offers.rb").to_s

# Revisão do ADR 0027 (2026-10-05): a coluna nasce false para as linhas que já
# existem, e o down a remove. DDL transacional: tudo num savepoint desfeito.
RSpec.describe "Migração de cidade 20261005300001 (AddSuggestionOnlyToTriageOffers)" do
  def conn = ApplicationRecord.connection
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { AddSuggestionOnlyToTriageOffers.new.exec_migration(conn, direction) }
    TriageOffer.reset_column_information
  end

  it "linha existente fica false; down remove a coluna" do
    admin = staff_with("migracao-#{SecureRandom.hex(3)}@cidade.gov.br")
    ApplicationRecord.transaction(requires_new: true) do
      migrate(:down)
      expect(conn.columns(:triage_offers).map(&:name)).not_to include("suggestion_only")
      row = TriageOffer.create!(protocol_name: "saude-do-idoso", updated_by_user: admin)
      migrate(:up)
      expect(row.reload.suggestion_only).to be(false)
      raise ActiveRecord::Rollback
    end
  ensure
    TriageOffer.reset_column_information
  end
end
