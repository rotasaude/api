require "rails_helper"

RSpec.describe ReportSnapshot, type: :model do
  describe "#url" do
    around do |ex|
      orig = ENV["WPDA_PUBLIC_BASE"]
      ENV["WPDA_PUBLIC_BASE"] = "https://wpda.example/"
      ex.run
      ENV["WPDA_PUBLIC_BASE"] = orig
    end

    it "aponta pro wpda com o token em query param (sem barra dupla)" do
      snap = ReportSnapshot.new(token: "abc123")
      expect(snap.url).to eq("https://wpda.example/?token=abc123")
    end
  end
end
