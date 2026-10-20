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

  describe "#coat_of_arms_path" do
    include CoatOfArmsHelpers

    it "round-trips a checksum with +, / and = through the query string" do
      city = create(:city, slug: "brasao")
      city.coat_of_arms.attach(io: StringIO.new(coat_png(64, 64)), filename: "b.png", content_type: "image/png")
      checksum = "ab+cd/ef0="
      allow_any_instance_of(ActiveStorage::Blob).to receive(:checksum).and_return(checksum)

      path = city.coat_of_arms_path

      expect(path).to include("v=ab%2Bcd%2Fef0%3D")
      expect(Rack::Utils.parse_query(URI(path).query)["v"]).to eq(checksum)
    end
  end
end
