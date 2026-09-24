require "rails_helper"

RSpec.describe HealthUnit do
  it "nome único sem distinguir maiúsculas" do
    described_class.create!(name: "UBS Centro", kind: "ubs")
    dup = described_class.new(name: "ubs centro", kind: "upa")
    expect(dup).not_to be_valid
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "tipo precisa ser conhecido" do
    expect(described_class.new(name: "X", kind: "clinica")).not_to be_valid
  end

  it "lista só as ativas" do
    a = described_class.create!(name: "A", kind: "ubs")
    described_class.create!(name: "B", kind: "upa", active: false)
    expect(described_class.active_units).to eq([a])
  end
end
