require "rails_helper"

RSpec.describe CareLines::Eligibility do
  let(:on) { Date.new(2026, 10, 22) }
  let(:entries) { CareLines::Templates::Load.entries.index_by { |e| e["key"] } }

  def rules(key) = entries.fetch(key)["eligibility"]
  def person(age: 40, sex: "female", **attrs) = CareLines::Person.new(birth_date: on.prev_year(age) - 1, sex: sex, **attrs)

  {
    [ "diabetes_c4", { problems: [ %w[cid10 E119] ] } ] => "problem",
    [ "diabetes_c4", { problems: [ %w[ciap2 K86] ], declared: %w[diabetes] } ] => "declared",
    [ "diabetes_c4", { problems: [ %w[ciap2 K86] ] } ] => nil,
    [ "hypertension_c5", { problems: [ %w[cid10 I150] ] } ] => "problem",
    [ "pregnancy_c3", { problems: [ %w[ciap2 W78] ] } ] => "problem",
    [ "pregnancy_c3", { problems: [ %w[ciap2 W78], %w[ciap2 W82] ] } ] => nil, # aborto exclui
    [ "elderly_c6", { age: 60 } ] => "age_sex",
    [ "elderly_c6", { age: 59 } ] => nil,
    [ "women_c7", { age: 9 } ] => "age_sex",
    [ "women_c7", { age: 70 } ] => nil,
    [ "women_c7", { age: 30, sex: "male" } ] => nil,
    [ "women_c7", { age: 30, sex: "male", gender_identity: "trans_man" } ] => "age_sex",
    [ "women_c7", { age: 30, sex: "female", gender_identity: "trans_woman" } ] => nil
  }.each do |(key, attrs), expected|
    it "#{key} #{attrs} → #{expected.inspect}" do
      expect(described_class.match(rules(key), person(**attrs), on: on)).to eq(expected)
    end
  end

  it "criança: até 730 dias de vida" do
    baby = CareLines::Person.new(birth_date: on - 730)
    expect(described_class.match(rules("child_c2"), baby, on: on)).to eq("age_sex")
    expect(described_class.match(rules("child_c2"), CareLines::Person.new(birth_date: on - 731), on: on)).to be_nil
  end

  it "denominador não conta declaração; encerramento só com todos os elegíveis resolvidos" do
    declared = person(declared: %w[diabetes])
    expect(described_class.denominator?(rules("diabetes_c4"), declared, on: on)).to be(false)
    both = person(problems: [ %w[cid10 E11] ], resolved_problems: [ %w[ciap2 T90] ])
    expect(described_class.closure?(rules("diabetes_c4"), both)).to be(false)
    resolved = person(problems: [ %w[ciap2 K86] ], resolved_problems: [ %w[ciap2 T90] ])
    expect(described_class.closure?(rules("diabetes_c4"), resolved)).to be(true)
    expect(described_class.closure?(rules("elderly_c6"), resolved)).to be(false)
  end

  describe "linha própria só com declaração e idade (a demografia é filtro, a origem é a declaração)" do
    let(:own_line) { { "declared" => %w[mental_health], "age_min_years" => 18 } }

    it "adulto sem declaração → nil" do
      adult = person(age: 30)
      expect(described_class.match(own_line, adult, on: on)).to be_nil
      expect(described_class.denominator?(own_line, adult, on: on)).to be(false)
    end

    it "adulto com declaração → declared, fora do denominador" do
      adult = person(age: 30, declared: %w[mental_health])
      expect(described_class.match(own_line, adult, on: on)).to eq("declared")
      expect(described_class.denominator?(own_line, adult, on: on)).to be(false)
    end

    it "menor com declaração → nil" do
      minor = person(age: 15, declared: %w[mental_health])
      expect(described_class.match(own_line, minor, on: on)).to be_nil
      expect(described_class.denominator?(own_line, minor, on: on)).to be(false)
    end
  end

  it "o código casa só na terminologia dele" do
    expect(described_class.codes_match?({ "cid10" => %w[E11] }, [ %w[ciap2 E11] ])).to be(false)
    expect(described_class.codes_match?({ "cid10" => %w[E11] }, [ %w[cid10 E119] ])).to be(true)
  end
end
