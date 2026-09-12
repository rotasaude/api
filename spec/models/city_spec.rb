require "rails_helper"

RSpec.describe City do
  # I4: CityCatalog.find_by_host returns nil for a reserved subdomain before
  # ever touching the database, so a city created with one of those slugs
  # would provision successfully and then 404 forever, silently. Catch it at
  # creation instead.
  it "rejects a reserved slug" do
    city = build(:city, slug: "admin")

    expect(city).not_to be_valid
    expect(city.errors[:slug]).to be_present
  end

  it "accepts a slug that is not reserved" do
    city = build(:city, slug: "naoreservado")

    expect(city).to be_valid
  end
end
