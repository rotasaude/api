require "rails_helper"

RSpec.describe "Conversation.for re-onboarding (F-02.8)", type: :model do
  it "returns the existing active conversation" do
    existing = Conversation.create!(phone: "+5511970001", state: "consented")
    found = Conversation.for("+5511970001")
    expect(found.id).to eq(existing.id)
  end

  it "creates a fresh greeting conversation when only a terminal one exists (re-onboard)" do
    revoked = Conversation.create!(phone: "+5511970002", state: "revoked")
    fresh = Conversation.for("+5511970002")
    expect(fresh.id).not_to eq(revoked.id)
    expect(fresh.state).to eq("greeting")
  end

  it "creates a greeting conversation for a brand-new phone (the old create-path bug)" do
    fresh = Conversation.for("+5511970003")
    expect(fresh.state).to eq("greeting")
    expect(fresh).to be_persisted
  end
end
