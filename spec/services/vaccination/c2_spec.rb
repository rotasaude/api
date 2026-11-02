require "rails_helper"

# Nota metodológica do C2 (boa prática E): penta, VIP, SCR e pneumocócica com
# todas as doses, contadas POR COMPONENTE (a hexa conta para a penta e para a
# VIP), intervalo mínimo de 30 dias entre doses do mesmo componente e SCR só a
# partir dos 12 meses, por aritmética de calendário (Calendar::Age; intervalos
# em dias) (config/vaccination/c2_schedule.yml).
RSpec.describe Vaccination::C2 do
  let(:born) { Date.new(2025, 1, 1) }
  def dose(code, on) = { code: code, on: on }

  # Fixture do brief com a VIP de 121 dias movida para 151: a hexa (43) de 120
  # dias já é dose de pólio, e uma VIP 1 dia depois não conta (ver o teste
  # seguinte) — com 121 a pólio ficaria com 2 doses e o C2 não fecharia.
  it "penta por componente com hexa no meio; SCR antes de 12 meses não conta" do
    doses = [ dose("42", born + 60), dose("43", born + 120), dose("42", born + 180),
              dose("22", born + 61), dose("22", born + 151),
              dose("26", born + 60), dose("26", born + 120),
              dose("24", born + 300), dose("24", born + 370), dose("56", born + 450) ]
    expect(described_class.met_on(doses: doses, birth_date: born)).to eq(born + 450)
  end

  it "a hexa é dose de pólio: VIP 1 dia depois dela não conta" do
    doses = [ dose("42", born + 60), dose("43", born + 120), dose("42", born + 180),
              dose("22", born + 61), dose("22", born + 121),
              dose("26", born + 60), dose("26", born + 120),
              dose("24", born + 370), dose("56", born + 450) ]
    expect(described_class.met_on(doses: doses, birth_date: born)).to be_nil
    expect(described_class.met_on(doses: doses + [ dose("22", born + 200) ], birth_date: born)).to eq(born + 450)
  end

  it "intervalo menor que 30 dias não conta a segunda dose" do
    doses = [ dose("26", born + 60), dose("26", born + 80) ]
    expect(described_class.met_on(doses: doses, birth_date: born)).to be_nil
  end

  it "código com zero à esquerda é o mesmo (hepatite B 09 = 9) e código fora do C2 é ignorado" do
    full = [ dose("39", born + 60), dose("39", born + 120), dose("39", born + 180),
             dose("09", born), dose("9", born + 60), dose("09", born + 120),
             dose("22", born + 60), dose("22", born + 120), dose("22", born + 180),
             dose("24", born + 365), dose("24", born + 400),
             dose("59", born + 60), dose("59", born + 120), dose("15", born + 1) ]
    expect(described_class.met_on(doses: full, birth_date: born)).to eq(born + 400)
    expect(described_class.met_on(doses: full.reject { |d| d[:code] == "9" }, birth_date: born)).to be_nil
  end

  describe "SCR a partir dos 12 meses de calendário (não 365 dias corridos)" do
    def complete_except_mmr(birth)
      [ dose("43", birth + 60), dose("43", birth + 120), dose("43", birth + 180), dose("26", birth + 60), dose("26", birth + 120) ]
    end

    it "véspera dos 12 meses não conta; o dia dos 12 meses conta" do
      birth = Date.new(2024, 5, 10)
      eve = complete_except_mmr(birth) + [ dose("24", Date.new(2025, 5, 9)), dose("56", Date.new(2025, 7, 1)) ]
      expect(described_class.met_on(doses: eve, birth_date: birth)).to be_nil
      day = complete_except_mmr(birth) + [ dose("24", Date.new(2025, 5, 10)), dose("56", Date.new(2025, 7, 1)) ]
      expect(described_class.met_on(doses: day, birth_date: birth)).to eq(Date.new(2025, 7, 1))
    end

    it "nascido em 01/03/2023 com dose em 29/02/2024 (dia 365, 11 meses e 28 dias): não conta" do
      birth = Date.new(2023, 3, 1)
      doses = complete_except_mmr(birth) + [ dose("24", Date.new(2024, 2, 29)), dose("56", Date.new(2024, 4, 1)) ]
      expect(described_class.met_on(doses: doses, birth_date: birth)).to be_nil
      later = complete_except_mmr(birth) + [ dose("24", Date.new(2024, 3, 1)), dose("56", Date.new(2024, 4, 1)) ]
      expect(described_class.met_on(doses: later, birth_date: birth)).to eq(Date.new(2024, 4, 1))
    end
  end

  it "sem nascimento ou sem doses: nil" do
    expect(described_class.met_on(doses: [ dose("42", born) ], birth_date: nil)).to be_nil
    expect(described_class.met_on(doses: [], birth_date: born)).to be_nil
  end
end
