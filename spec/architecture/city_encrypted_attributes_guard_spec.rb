require "rails_helper"

# CityEncryption::CITY_KEYED_TARGETS is the single source CityRekey::TARGETS
# and ReencryptionJob::TARGETS read from (see the comment on
# CITY_KEYED_TARGETS) — but nothing stops a new `encrypts` on a city model
# (ApplicationRecord/CityRecord) from being added without a matching entry in
# that list. Without an entry there, city:rotate_key and ReencryptionJob
# silently skip the attribute forever (found for real: User#otp_pending_secret
# was `encrypts`-ed without a CITY_KEYED_TARGETS entry, Task 1 of the pending-
# authenticator plan). This guard reads the code instead of trusting memory:
# every `encrypts`-declared attribute of a city model must appear in
# CITY_KEYED_TARGETS.
RSpec.describe "City-keyed encryption targets guard" do
  it "lists every encrypts-declared attribute of a city model in CityEncryption::CITY_KEYED_TARGETS" do
    Rails.application.eager_load!

    registered = CityEncryption::CITY_KEYED_TARGETS.map { |model, attribute| [ model, attribute.to_sym ] }

    declared = ApplicationRecord.descendants
      .select { |model| model.respond_to?(:encrypted_attributes) && model.encrypted_attributes.present? }
      .flat_map { |model| model.encrypted_attributes.map { |attribute| [ model, attribute.to_sym ] } }

    expect(declared - registered).to eq([])
  end
end
