require "rails_helper"

RSpec.describe Citizens::UpdateContactPreferences do
  include ActiveSupport::Testing::TimeHelpers

  let(:citizen) { person! }

  def payloads = DomainEvent.where(name: "citizen.contact_preferences_changed").order(:occurred_at, :id).map(&:payload)

  it "liga o opt-in com a hora, silencia, e publica um evento por mudança, sem telefone nem CPF" do
    freeze_time do
      described_class.call(citizen: citizen, changes: { "sms_opt_in" => true })
      expect(citizen.reload.contact_preference).to have_attributes(sms_opt_in: true, sms_opt_in_changed_at: Time.current)
    end
    described_class.call(citizen: citizen, changes: { "notices_muted" => true })
    expect(payloads).to eq([
      { "citizen_id" => citizen.id, "sms_opt_in" => true, "notices_muted" => false },
      { "citizen_id" => citizen.id, "sms_opt_in" => true, "notices_muted" => true }
    ])
  end

  it "nada muda: ok, sem linha nova e sem evento" do
    result = described_class.call(citizen: citizen, changes: { "sms_opt_in" => false, "notices_muted" => false })
    expect(result).to be_ok
    expect(CitizenContactPreference.count).to eq(0)
    expect(payloads).to be_empty
  end

  it "repetir o mesmo valor numa linha existente não publica de novo" do
    described_class.call(citizen: citizen, changes: { "sms_opt_in" => true })
    described_class.call(citizen: citizen, changes: { "sms_opt_in" => true })
    expect(payloads.size).to eq(1)
  end

  it "silenciar não mexe na hora do opt-in" do
    described_class.call(citizen: citizen, changes: { "notices_muted" => true })
    expect(citizen.reload.contact_preference.sms_opt_in_changed_at).to be_nil
  end

  it "sem chave conhecida, ou valor não booleano: invalid_preferences" do
    [ {}, { "cpf" => "1" }, { "sms_opt_in" => "true" }, { "notices_muted" => nil } ].each do |changes|
      expect(described_class.call(citizen: citizen, changes: changes).reason).to eq(:invalid_preferences), changes.inspect
    end
  end
end
