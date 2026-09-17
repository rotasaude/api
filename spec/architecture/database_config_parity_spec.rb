require "rails_helper"

# Guards C1: a stanza present under development/test but missing under
# production only surfaces at boot, under `config.eager_load = true`, as
# `AdapterNotSpecified` — by then it is a production incident. Catch the
# missing stanza here instead, by diffing the four environments' keys
# (development, test, production, staging).
RSpec.describe "Database configuration parity" do
  let(:raw) do
    YAML.safe_load(ERB.new(Rails.root.join("config/database.yml").read).result, aliases: true)
  end

  it "declares the same database keys under production as under development" do
    expect(raw["production"].keys).to match_array(raw["development"].keys)
  end

  # Fix wave (Minor #6): staging is a YAML alias of production
  # (`staging: *production`), so this comparison cannot fail — it proves the
  # staging stanza exists, not that it stays in sync (drift is impossible by
  # construction, not detected here).
  it "declares the same database keys under staging as under production" do
    expect(raw["staging"].keys).to match_array(raw["production"].keys)
  end

  it "declares a platform database in every environment" do
    %w[development test production staging].each do |env|
      expect(raw[env]).to have_key("platform"), "config/database.yml: no platform stanza under #{env}"
    end
  end
end
