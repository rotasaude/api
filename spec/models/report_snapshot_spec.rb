require "rails_helper"

RSpec.describe ReportSnapshot, type: :model do
  describe "#url" do
    around do |ex|
      Current.city = TEST_CITY_A
      ex.run
      Current.reset
    end

    it "aponta pro wpda da cidade corrente, com o token em query param (sem barra dupla)" do
      snap = ReportSnapshot.new(token: "abc123")
      expect(snap.url).to eq("http://#{TEST_CITY_A.slug}.localhost:5175/wpda/?token=abc123")
    end
  end
end
