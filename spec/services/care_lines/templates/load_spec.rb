require "rails_helper"

RSpec.describe CareLines::Templates::Load do
  it "cria a versão 1 das seis linhas e é idempotente (nunca sobrescreve a curadoria)" do
    expect(described_class.call).to eq(created: 6)
    CareLines::Templates::Save.call(CareLineTemplate.current("elderly_c6").attributes.slice(*%w[key indicator declared_condition eligibility practices])
                                                        .merge("name" => "Pessoa idosa (curada)"))
    expect(described_class.call).to eq(created: 0)
    expect(CareLineTemplate.latest.map { |t| [ t.key, t.version ] })
      .to eq([ [ "child_c2", 1 ], [ "pregnancy_c3", 1 ], [ "diabetes_c4", 1 ], [ "hypertension_c5", 1 ], [ "elderly_c6", 2 ], [ "women_c7", 1 ] ])
  end
end
