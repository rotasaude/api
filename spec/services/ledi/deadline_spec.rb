require "rails_helper"

# Spec §6.5 / contract §8: official SIAPS table preferred; fallback = 10th
# national business day of the following month.
RSpec.describe Ledi::Deadline do
  computed = {
    "202601" => "2026-02-13", "202602" => "2026-03-13", "202603" => "2026-04-15", "202604" => "2026-05-15",
    "202605" => "2026-06-15",
    "202606" => "2026-07-14", "202607" => "2026-08-14", "202608" => "2026-09-15", "202609" => "2026-10-15",
    "202610" => "2026-11-16", "202611" => "2026-12-14", "202612" => "2027-01-15"
  }
  # Official SIAPS date differs only for 202605 (Corpus Christi counted as business day officially).
  official = computed.merge("202605" => "2026-06-16")

  official.each do |competence, deadline|
    it("on(#{competence}) → #{deadline} (official table)") { expect(described_class.on(competence)).to eq(Date.parse(deadline)) }
  end

  computed.each do |competence, deadline|
    it("estimated_on(#{competence}) → #{deadline} (computed)") { expect(described_class.estimated_on(competence)).to eq(Date.parse(deadline)) }
  end

  it "table miss (2027) falls back to the computation" do
    expect(described_class::TABLE).not_to have_key("202701")
    expect(described_class.on("202701")).to eq(Date.new(2027, 2, 16))
    expect(described_class.on("202701")).to eq(described_class.estimated_on("202701"))
  end

  it "estimated_on ignores the table" do
    expect(described_class.on("202605")).not_to eq(described_class.estimated_on("202605"))
  end

  it "the table is frozen and holds the 12 competences of 2026" do
    expect(described_class::TABLE).to be_frozen
    expect(described_class::TABLE.keys).to eq((1..12).map { |m| format("2026%02d", m) })
  end

  it "Carnaval de 2027 (08 e 09/02) empurra o prazo de janeiro" do
    expect(Ledi::BusinessCalendar.easter(2027)).to eq(Date.new(2027, 3, 28))
    expect(described_class.estimated_on("202701")).to eq(Date.new(2027, 2, 16))
  end

  it "feriados fixos, Sexta-feira Santa e Consciência Negra" do
    holidays = Ledi::BusinessCalendar.holidays(2026)
    expect(holidays).to include(Date.new(2026, 4, 3), Date.new(2026, 11, 20), Date.new(2026, 10, 12),
                                Date.new(2026, 2, 16), Date.new(2026, 2, 17), Date.new(2026, 6, 4))
    expect(Ledi::BusinessCalendar.business_day?(Date.new(2026, 10, 10))).to be(false) # sábado
  end

  it "business_days_left conta hoje e o dia do prazo; depois do prazo é 0" do
    expect(described_class.business_days_left("202610", today: Date.new(2026, 11, 3))).to eq(10)
    expect(described_class.business_days_left("202610", today: Date.new(2026, 11, 16))).to eq(1)
    expect(described_class.business_days_left("202610", today: Date.new(2026, 11, 17))).to eq(0)
    expect(described_class.business_days_left("202610", today: Date.new(2026, 10, 20))).to eq(19)
  end

  it "business_days_left uses the official date when present" do
    # 202605: official 06-16 (Tue); 06-15 (Mon) -> 2 business days, estimate would give 1.
    expect(described_class.business_days_left("202605", today: Date.new(2026, 6, 15))).to eq(2)
    expect(described_class.business_days_left("202605", today: Date.new(2026, 6, 17))).to eq(0)
  end

  it "competência corrente e anterior, e validação" do
    expect(described_class.current(Date.new(2026, 1, 5))).to eq("202601")
    expect(described_class.previous(Date.new(2026, 1, 5))).to eq("202512")
    expect(%w[202610 202613 2026-10 20261].map { |c| described_class.valid?(c) }).to eq([ true, false, false, false ])
  end
end
