require "rails_helper"

# Módulo 35b, Task 13 (ADR 0054; contrato §6; decisão do coordenador na
# revisão): a prevalência do inquérito de leishmaniose POR CÃO. Resultado
# final = ELISA reagente ou não reagente, ou DPP não reagente (negativo); o
# ELISA inconclusivo não é final (o cão espera reteste), nem DPP reagente sem
# ELISA, DPP inválido ou coleta sem DPP. Examinados = cães com resultado final
# no inquérito; reagentes = cães cujo ÚLTIMO resultado final (coleta, criação)
# é reagente nos dois. O reteste nunca conta duas vezes. Uma casa; nil sem
# examinado.
RSpec.describe Zoonoses::Prevalence, type: :model do
  let!(:city) { zoonoses_city! }
  let(:neighborhood) { Neighborhood.create!(name: "Bairro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "1") }
  let(:survey) { leish_survey!(blocks: [ block ]) }
  let(:today) { Time.zone.today }
  let(:seq) { [ 0 ] }

  def test!(dpp: nil, elisa: nil, survey: self.survey, animal: animal!, collected_on: today)
    seq[0] += 1
    LeishTest.create!(leish_survey: survey, animal: animal, collected_on: collected_on, label: "LV-#{today.year}-AVUL-#{format('%04d', seq[0])}",
                      dpp_result: dpp, dpp_on: (collected_on if dpp), elisa_result: elisa, elisa_on: (collected_on if elisa))
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

  it "DPP não reagente conta como negativo; uma casa" do
    test!(dpp: "non_reactive")
    test!(dpp: "reactive", elisa: "non_reactive")
    test!(dpp: "reactive", elisa: "reactive")
    expect(described_class.for(survey)).to eq(examined: 3, reactive: 1, prevalence: 33.3)
  end

  it "cão só com ELISA inconclusivo → não examinado" do
    test!(dpp: "reactive", elisa: "inconclusive")
    test!(dpp: "non_reactive")
    expect(described_class.for(survey)).to eq(examined: 1, reactive: 0, prevalence: 0.0)
  end

  it "mesmo cão, inconclusivo e depois reagente → examinado 1, reagente 1, 100.0" do
    dog = animal!
    test!(animal: dog, dpp: "reactive", elisa: "inconclusive", collected_on: today - 20)
    test!(animal: dog, dpp: "reactive", elisa: "reactive", collected_on: today - 2)
    expect(described_class.for(survey)).to eq(examined: 1, reactive: 1, prevalence: 100.0)
  end

  it "mesmo cão, reagente e depois reteste não reagente → examinado 1, reagente 0; vale o último pela coleta, não pela criação" do
    dog = animal!
    test!(animal: dog, dpp: "reactive", elisa: "reactive", collected_on: today - 20)
    test!(animal: dog, dpp: "non_reactive", collected_on: today - 2)
    # Reteste lançado depois mas coletado antes de outro: manda a coleta mais recente.
    other = animal!
    test!(animal: other, dpp: "reactive", elisa: "reactive", collected_on: today - 1)
    test!(animal: other, dpp: "non_reactive", collected_on: today - 9)
    # Uma coleta posterior sem resultado final não apaga o último final.
    test!(animal: dog, dpp: "reactive", collected_on: today)
    expect(described_class.for(survey)).to eq(examined: 2, reactive: 1, prevalence: 50.0)
  end

  it "sem examinado → prevalência nil; os testes de outro inquérito e os avulsos não entram" do
    test!(dpp: "reactive")
    test!(dpp: "non_reactive", survey: leish_survey!(blocks: [ block ]))
    test!(dpp: "non_reactive", survey: nil)
    expect(described_class.for(survey)).to eq(examined: 0, reactive: 0, prevalence: nil)
  end
end
