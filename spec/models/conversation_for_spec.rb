require "rails_helper"

RSpec.describe "Conversation.for re-onboarding (F-02.8)", type: :model do
  def make_muni(slug)
    Municipality.create!(name: "For #{slug}", slug: slug, ibge_code: "3500040")
  end

  it "returns the existing active conversation" do
    m = make_muni("for-active")
    existing = Conversation.create!(municipality_id: m.id, phone: "+5511970001", state: "consented")
    found = Conversation.for("+5511970001", municipality_id: m.id)
    expect(found.id).to eq(existing.id)
  end

  it "creates a fresh greeting conversation when only a terminal one exists (re-onboard)" do
    m = make_muni("for-terminal")
    revoked = Conversation.create!(municipality_id: m.id, phone: "+5511970002", state: "revoked")
    fresh = Conversation.for("+5511970002", municipality_id: m.id)
    expect(fresh.id).not_to eq(revoked.id)
    expect(fresh.state).to eq("greeting")
  end

  it "creates a greeting conversation for a brand-new phone (the old create-path bug)" do
    m = make_muni("for-new")
    fresh = Conversation.for("+5511970003", municipality_id: m.id)
    expect(fresh.state).to eq("greeting")
    expect(fresh).to be_persisted
  end
end
