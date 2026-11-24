require "rails_helper"

# Módulo 35b, Task 13 (ADR 0054; contrato §6): a prevalência do inquérito de
# leishmaniose. Reagente = DPP e ELISA reagentes; examinado com resultado
# final = ELISA lançado (qualquer resultado) ou DPP não reagente (negativo);
# DPP reagente sem ELISA, DPP inválido e coleta sem DPP não contam. Uma casa
# decimal; nil sem examinado.
RSpec.describe Zoonoses::Prevalence, type: :model do
  let!(:city) { zoonoses_city! }
  let(:neighborhood) { Neighborhood.create!(name: "Bairro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "1") }
  let(:survey) { leish_survey!(blocks: [ block ]) }
  let(:today) { Time.zone.today }
  let(:seq) { [ 0 ] }

  def test!(dpp: nil, elisa: nil, survey: self.survey)
    seq[0] += 1
    LeishTest.create!(leish_survey: survey, animal: animal!, collected_on: today, label: "LV-#{today.year}-AVUL-#{format('%04d', seq[0])}",
                      dpp_result: dpp, dpp_on: (today if dpp), elisa_result: elisa, elisa_on: (today if elisa))
  end

  it "10 examinados, 2 reagentes → 20.0" do
    2.times { test!(dpp: "reactive", elisa: "reactive") }
    3.times { test!(dpp: "reactive", elisa: "non_reactive") }
    5.times { test!(dpp: "non_reactive") }
    expect(described_class.for(survey)).to eq(examined: 10, reactive: 2, prevalence: 20.0)
  end

  it "DPP reagente sem ELISA não conta como examinado; nem DPP inválido nem coleta sem DPP" do
    test!(dpp: "reactive")
    test!(dpp: "invalid")
    test!
    test!(dpp: "reactive", elisa: "reactive")
    expect(described_class.for(survey)).to eq(examined: 1, reactive: 1, prevalence: 100.0)
  end

  it "DPP não reagente conta como negativo; ELISA inconclusivo é examinado, não reagente; uma casa" do
    test!(dpp: "non_reactive")
    test!(dpp: "reactive", elisa: "inconclusive")
    test!(dpp: "reactive", elisa: "reactive")
    expect(described_class.for(survey)).to eq(examined: 3, reactive: 1, prevalence: 33.3)
  end

  it "sem examinado → prevalência nil; os testes de outro inquérito e os avulsos não entram" do
    test!(dpp: "reactive")
    test!(dpp: "non_reactive", survey: leish_survey!(blocks: [ block ]))
    test!(dpp: "non_reactive", survey: nil)
    expect(described_class.for(survey)).to eq(examined: 0, reactive: 0, prevalence: nil)
  end
end
