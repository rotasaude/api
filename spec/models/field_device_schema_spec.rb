require "rails_helper"

# Módulo 24b (ADR 0052): o banco do aparelho de campo e da sincronização. O token
# só existe como SHA-256 (único, imutável); revogar é final; o livro de
# idempotência e as lápides só crescem.
RSpec.describe "Esquema do aparelho de campo e da sincronização (ADR 0052)", type: :model do
  before { home_visit_city!(collective: true) }

  def refused(pattern = nil, &block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  def accepted(&block)
    expect { ApplicationRecord.transaction(requires_new: true, &block) }.not_to raise_error
  end

  let!(:team) { registry_team! }
  let!(:agent) { field_agent!(team: team) }

  def token = "rsf_#{SecureRandom.urlsafe_base64(32)}"

  def device!(validate: false, **over)
    record = FieldDevice.new({ user: agent, professional: agent.professional, name: "Tablet da microárea 3",
                               token_digest: FieldDevice.digest(token) }.merge(over))
    record.save!(validate: validate)
    record
  end

  it "o digest é único e nunca muda" do
    raw = token
    device = device!(token_digest: FieldDevice.digest(raw))
    expect(device.token_digest).to match(/\A[0-9a-f]{64}\z/)
    expect { device!(token_digest: FieldDevice.digest(raw)) }
      .to raise_error(ActiveRecord::RecordNotUnique, /index_field_devices_on_token_digest/)
    refused(/ck_field_devices_token_digest/) { device!(token_digest: "ABC" * 21 + "A") }
    refused(/ck_field_devices_token_digest/) { device!(token_digest: "a" * 63) }
    refused(/field_devices/) { device.update_columns(token_digest: FieldDevice.digest(token)) }
    refused(/field_devices/) { device.update_columns(name: "Outro nome") }
    refused(/field_devices/) { device.update_columns(user_id: field_agent!(team: team).id) }
    refused(/field_devices/) { device.update_columns(professional_id: field_agent!(team: team).professional.id) }
    refused(/field_devices/) { device.update_columns(created_at: 1.day.ago) }
    refused(/field_devices/) { device.delete }
    accepted { device.update_columns(last_used_at: Time.current) }
    accepted { device.update_columns(last_used_at: Time.current + 1.minute) }
  end

  it "o nome tem de 1 a 60 caracteres" do
    refused(/ck_field_devices_name/) { device!(name: "   ") }
    refused(/ck_field_devices_name/) { device!(name: "a" * 61) }
    accepted { device!(name: "a" * 60) }
  end

  it "a validação do nome aplara como o CHECK" do
    expect(FieldDevice.new(name: "  " + "a" * 60 + "  ")).to be_valid.or(satisfy { |d| d.errors[:name].empty? })
    expect(FieldDevice.new(name: " " * 5).tap(&:valid?).errors[:name]).not_to be_empty
    expect(FieldDevice.new(name: "a" * 61).tap(&:valid?).errors[:name]).not_to be_empty
  end

  it "revogar é final" do
    device = device!
    refused(/field_devices/) { device.update_columns(revoked_at: Time.current) }
    refused(/ck_field_devices_revoked\b/) { device!(revoked_at: Time.current) }
    refused(/ck_field_devices_revoked\b/) { device!(revoked_reason: "user") }
    refused(/ck_field_devices_revoked_reason/) { device!(revoked_at: Time.current, revoked_reason: "outro") }
    refused(/ck_field_devices_revoked_by/) do
      device!(revoked_at: Time.current, revoked_reason: "membership_ended", revoked_by_user_id: agent.id)
    end
    accepted { device!(revoked_at: Time.current, revoked_reason: "membership_ended") }

    expect(device.reload).not_to be_revoked
    expect(FieldDevice.active).to include(device)
    device.update!(revoked_at: Time.current, revoked_reason: "user", revoked_by_user_id: agent.id)
    expect(device).to be_revoked
    expect(FieldDevice.active).not_to include(device)
    refused(/field_devices/) { device.update_columns(revoked_at: Time.current + 1.minute) }
    refused(/field_devices/) { device.update_columns(revoked_at: nil, revoked_reason: nil, revoked_by_user_id: nil) }
    refused(/field_devices/) { device.update_columns(revoked_reason: "admin") }
    accepted { device.update_columns(last_used_at: Time.current) }
  end

  it "a re-cifra ligada não abre exceção (o aparelho não tem coluna cifrada)" do
    device = device!
    refused(/field_devices/) do
      ApplicationRecord.connection.execute("SET LOCAL rota.reencrypting = 'on'")
      device.update_columns(name: "Outro nome")
    end
  end

  it "by_token acha pelo SHA-256 e ignora texto malformado" do
    raw = token
    device = device!(token_digest: FieldDevice.digest(raw))
    revoked = device!(token_digest: FieldDevice.digest("rsf_#{'r' * 43}"), revoked_at: Time.current, revoked_reason: "membership_ended")
    expect(FieldDevice.digest(raw)).to eq(Digest::SHA256.hexdigest(raw))
    expect(FieldDevice.by_token(raw)).to eq(device)
    expect(FieldDevice.by_token("rsf_#{'r' * 43}")).to eq(revoked)
    expect(FieldDevice.by_token(token)).to be_nil
    [ nil, 123, [ raw ], "", "rsf_", "xyz_#{'a' * 43}", "rsf_#{'a' * 35}", "rsf_#{'a' * 57}", raw.delete_prefix("rsf_") ].each do |bad|
      expect(FieldDevice.by_token(bad)).to be_nil
    end
  end

  it "livro e tombstones são só acréscimo" do
    device = device!
    receipt = FieldSyncReceipt.create!(client_uuid: SecureRandom.uuid, field_device: device, user: agent,
                                       item_type: "home_visit", result_type: "HomeVisit", result_id: SecureRandom.uuid)
    expect do
      FieldSyncReceipt.create!(client_uuid: receipt.client_uuid, field_device: device, user: agent, item_type: "home_visit",
                               result_type: "HomeVisit", result_id: SecureRandom.uuid)
    end.to raise_error(ActiveRecord::RecordNotUnique, /idx_field_sync_receipts_client_uuid/)
    refused(/ck_field_sync_receipts_item_type/) do
      FieldSyncReceipt.new(client_uuid: SecureRandom.uuid, field_device: device, user: agent, item_type: "outro",
                           result_type: "HomeVisit", result_id: SecureRandom.uuid).save!(validate: false)
    end
    FieldSync::Catalog::ITEM_TYPES.each do |type|
      accepted do
        FieldSyncReceipt.create!(client_uuid: SecureRandom.uuid, field_device: device, user: agent, item_type: type,
                                 result_type: "X", result_id: SecureRandom.uuid)
      end
    end
    refused(/null value in column "result_id"/) do
      FieldSyncReceipt.new(client_uuid: SecureRandom.uuid, field_device: device, user: agent, item_type: "home_visit",
                           result_type: "X").save!(validate: false)
    end
    refused(/field_sync_receipts/) { receipt.update_columns(result_id: SecureRandom.uuid) }
    refused(/field_sync_receipts/) { receipt.delete }
    refused(/field_sync_receipts/) { FieldSyncReceipt.connection.execute("TRUNCATE field_sync_receipts CASCADE") }

    area = registry_micro_area!(team: team, code: "01")
    stone = FieldSyncTombstone.create!(entity_type: "household", entity_id: SecureRandom.uuid, micro_area: area, reason: "moved")
    FieldSync::Catalog::TOMBSTONE_REASONS.each do |reason|
      accepted { FieldSyncTombstone.create!(entity_type: "registration", entity_id: SecureRandom.uuid, micro_area: area, reason: reason) }
    end
    refused(/ck_field_sync_tombstones_entity_type/) do
      FieldSyncTombstone.new(entity_type: "family", entity_id: SecureRandom.uuid, micro_area: area, reason: "moved").save!(validate: false)
    end
    refused(/ck_field_sync_tombstones_reason/) do
      FieldSyncTombstone.new(entity_type: "household", entity_id: SecureRandom.uuid, micro_area: area, reason: "gone").save!(validate: false)
    end
    refused(/ck_field_sync_tombstones_reason/) do
      FieldSyncTombstone.new(entity_type: "household", entity_id: SecureRandom.uuid, micro_area: area, reason: "out_of_scope").save!(validate: false)
    end
    refused(/field_sync_tombstones/) { stone.update_columns(reason: "erased") }
    refused(/field_sync_tombstones/) { stone.delete }
    refused(/field_sync_tombstones/) { FieldSyncTombstone.connection.execute("TRUNCATE field_sync_tombstones CASCADE") }
  end

  it "visita e atividade apontam para o aparelho (FK)" do
    device = device!
    day = home_visit_day!(agent: agent, team: team)
    accepted { home_visit!(day: day, origin: "field_app", field_device_id: device.id) }
    refused(/foreign key|violates/i) { home_visit!(day: day, origin: "field_app", field_device_id: SecureRandom.uuid) }
    activity = lambda do |device_id|
      CollectiveActivity.new(client_uuid: SecureRandom.uuid, team: team, health_unit: team.health_unit, professional: agent.professional,
                             cbo: "322255", recorded_by_user: agent, held_on: Time.zone.today, shift: 1, activity_type: 1,
                             place_text: "Praça", participants_count: 3, origin: "field_app", field_device_id: device_id).save!(validate: false)
    end
    accepted { activity.call(device.id) }
    refused(/foreign key|violates/i) { activity.call(SecureRandom.uuid) }
  end

  it "inspect não mostra o digest" do
    raw = token
    device = device!(token_digest: FieldDevice.digest(raw))
    [ device.inspect, device.to_s, device.pretty_inspect, device.as_json.to_s, device.to_json ].each do |text|
      expect(text).not_to include(device.token_digest)
      expect(text).not_to include(raw)
      expect(text).not_to include(device.name)
      expect(text).to include(device.id)
    end
  end

  it "o índice de ativos por usuário existe e é parcial" do
    definition = ApplicationRecord.connection.select_value(
      "SELECT indexdef FROM pg_indexes WHERE indexname = 'idx_field_devices_active_by_user'"
    )
    expect(definition).to include("(user_id)").and include("revoked_at IS NULL")
  end
end
