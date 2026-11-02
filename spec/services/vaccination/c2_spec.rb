require "rails_helper"

# Nota metodológica do C2 (boa prática E): penta, VIP, SCR e pneumocócica com
# todas as doses, contadas POR COMPONENTE (a hexa conta para a penta e para a
# VIP), intervalo mínimo de 30 dias entre doses do mesmo componente e SCR só a
# partir de 365 dias de vida (config/vaccination/c2_schedule.yml).
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

  it "sem nascimento ou sem doses: nil" do
    expect(described_class.met_on(doses: [ dose("42", born) ], birth_date: nil)).to be_nil
    expect(described_class.met_on(doses: [], birth_date: born)).to be_nil
  end
end
