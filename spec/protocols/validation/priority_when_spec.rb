require "rails_helper"

RSpec.describe Protocols::Validation::PriorityWhen do
  def defn(priority_when)
    {
      "steps" => [{ "id" => "idade", "answer_type" => "integer" }],
      "priority_when" => priority_when
    }
  end

  it "accepts a valid priority_when" do
    expect(described_class.call(defn([{ "when" => { "gt" => ["idade", 80] }, "priority" => 1 }]))).to eq([])
  end

  it "flags an invalid when" do
    expect(described_class.call(defn([{ "when" => { "gt" => ["ausente", 80] }, "priority" => 1 }]))).not_to be_empty
  end

  it "flags a priority outside 1..9 or missing" do
    expect(described_class.call(defn([{ "when" => { "gt" => ["idade", 80] }, "priority" => 10 }]))).not_to be_empty
    expect(described_class.call(defn([{ "when" => { "gt" => ["idade", 80] } }]))).not_to be_empty
  end

  it "is a no-op without priority_when" do
    expect(described_class.call({ "steps" => [] })).to eq([])
  end
end
