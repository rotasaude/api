require "rails_helper"
require Rails.root.join("db/city_migrate/20261113900001_add_field_locations.rb").to_s

# Módulo 24c (ADR 0053): o banco da coordenada do imóvel e da visita e os
# acréscimos do livro de idempotência. A coordenada é JSON cifrado com a chave
# da cidade; a versão do domicílio e a visita não a mudam depois de gravadas
# (a re-cifra passa); nada de coordenada em inspect.
RSpec.describe "Esquema da coordenada e do livro do app de campo (ADR 0053)", type: :model do
  before { home_visit_city! }

  POINT = { "latitude" => -25.42847123, "longitude" => -49.27325411, "accuracy_m" => 8.5, "source" => "gps" }.freeze
  OTHER = { "latitude" => -25.5, "longitude" => -49.3, "source" => "map" }.freeze

  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  def accepted(&block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.not_to raise_error
  end

  def raw(table, id) = ApplicationRecord.connection.select_value("SELECT location FROM #{table} WHERE id = '#{id}'")

  let(:team) { registry_team! }
  let(:agent) { field_agent!(team: team) }

  describe "versão do domicílio" do
    let(:household) { registry_household! }
    let!(:version) { registry_new_household_version!(household, location: POINT) }

    it "location grava e volta como Hash; no banco é texto cifrado" do
      expect(version.reload.location).to eq(POINT)
      stored = raw("household_versions", version.id)
      expect(stored).to be_present
      expect(stored).not_to include("25.42847123")
      expect(stored).not_to include("latitude")
      expect(household.versions.order(:version).first.location).to be_nil
    end

    it "a coordenada não muda depois de gravada, salvo a re-cifra" do
      refused(/household_versions/) { version.update_columns(location: OTHER.to_json) }
      accepted do
        HouseholdVersion.connection.execute("SET LOCAL rota.reencrypting = 'on'")
        version.update_columns(location: "re-cifrada")
      end
      refused(/household_versions/) do
        HouseholdVersion.connection.execute("SET LOCAL rota.reencrypting = 'on'")
        version.update_columns(location: "re-cifrada", property_type: "2")
      end
    end

    it "inspect não mostra a coordenada" do
      expect(version.inspect).to eq("#<HouseholdVersion id=#{version.id} household_id=#{household.id} version=#{version.version}>")
      expect(HouseholdVersion.new(location: POINT).inspect).not_to include("25.4")
    end
  end

  describe "visita" do
    let(:day) { home_visit_day!(agent: agent, team: team) }
    let!(:visit) { home_visit!(day: day, location: POINT) }

    it "location grava e volta como Hash; no banco é texto cifrado" do
      expect(visit.reload.location).to eq(POINT)
      stored = raw("home_visits", visit.id)
      expect(stored).to be_present
      expect(stored).not_to include("25.42847123")
      expect(home_visit!(day: day).location).to be_nil
    end

    it "a coordenada não muda, nem na folha aberta; a re-cifra passa" do
      expect(day).to be_open
      refused(/home_visits/) { visit.update_columns(location: OTHER.to_json) }
      refused(/home_visits/) { visit.update_columns(location: nil) }
      accepted do
        HomeVisit.connection.execute("SET LOCAL rota.reencrypting = 'on'")
        visit.update_columns(location: "re-cifrada")
      end
      refused(/home_visits/) do
        HomeVisit.connection.execute("SET LOCAL rota.reencrypting = 'on'")
        visit.update_columns(location: "re-cifrada", outcome: 3)
      end
    end

    it "inspect e as_json não mostram a coordenada" do
      [ visit.inspect, visit.to_s, visit.as_json.to_s ].each do |text|
        expect(text).not_to include("25.4")
        expect(text).not_to include("latitude")
      end
    end
  end

  describe "livro de idempotência" do
    let(:device) do
      FieldDevice.create!(user: agent, professional: agent.professional, name: "Tablet da microárea 3",
                          token_digest: FieldDevice.digest("rsf_#{SecureRandom.urlsafe_base64(32)}"))
    end

    def receipt(**over)
      FieldSyncReceipt.new({ client_uuid: SecureRandom.uuid, field_device: device, user: agent, item_type: "household",
                             result_type: "Household", result_id: SecureRandom.uuid }.merge(over))
    end

    it "aceita o item family" do
      accepted { receipt(item_type: "family").save!(validate: false) }
      refused(/ck_field_sync_receipts_item_type/) { receipt(item_type: "visit_sheet").save!(validate: false) }
    end

    it "result_version é nula ou a partir de 1" do
      accepted { receipt.save! }
      accepted { receipt(result_version: 4).save! }
      refused(/ck_field_sync_receipts_result_version/) { receipt(result_version: 0).save!(validate: false) }
      expect(FieldSyncReceipt.order(:created_at).pluck(:result_version)).to contain_exactly(nil, 4)
    end

    it "não há coluna do paciente criado (Q51)" do
      expect(FieldSyncReceipt.column_names).not_to include("result_patient_id")
    end
  end

  it "a migração é irreversível e espelha o catálogo" do
    expect { AddFieldLocations.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
    # A 20261116900003 (módulo 35a, W-4) acrescenta os dois itens de ovitrampa no
    # fim, e a 20261123900003 (módulo 35b, §11) os quatro de zoonoses.
    later = %w[ovitrap_installation ovitrap_collection animal rabies_vaccination leish_collection collar]
    expect([ AddFieldLocations::ITEM_TYPES, AddFieldLocations::REVOKED_REASONS ])
      .to eq([ FieldSync::Catalog::ITEM_TYPES - later, FieldSync::Catalog::REVOKED_REASONS ])
    expect(AddFieldLocations::REVOKED_WITH_AUTHOR).to match_array(FieldSync::Catalog::REVOKED_BY_PERSON)
  end
end
