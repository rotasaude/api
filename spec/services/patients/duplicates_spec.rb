require "rails_helper"

RSpec.describe Patients::Duplicates do
  before { clinical_city! }

  it "acha pelo nome normalizado + nascimento, filtra pela mãe, nunca pelo texto claro no banco" do
    a = Patients::CreateTyped.call(attrs: { "full_name" => "José  Antônio Pereira", "birth_date" => "1960-05-01", "sex" => "male",
                                            "mother_name" => "Maria Pereira", "no_cpf_reason" => "8" }, by: verifier!).payload[:patient]
    Patients::CreateTyped.call(attrs: { "full_name" => "Jose Antonio Pereira", "birth_date" => "1960-05-01", "sex" => "male",
                                        "mother_name" => "Ana Lima", "no_cpf_reason" => "8" }, by: verifier!)
    expect(described_class.call(full_name: "JOSE ANTONIO PEREIRA", birth_date: "1960-05-01").size).to eq(2)
    expect(described_class.call(full_name: "jose antonio pereira", birth_date: "1960-05-01", mother_name: "maria pereira")).to eq([ a ])
    expect(described_class.call(full_name: "Jose Antonio Pereira", birth_date: "1960-05-02")).to eq([])
    raw = ApplicationRecord.connection.select_value("SELECT match_key FROM patients WHERE id = '#{a.id}'")
    expect(raw).not_to include("jose")
  end

  # Decisão da coordenadora (2026-10-24): hífen e apóstrofo (também ’ e ‘)
  # viram espaço antes de colapsar — "Ana-Maria" = "Ana Maria", "D'Ávila" =
  # "D Ávila" = "D’Ávila". Nos dois sentidos: o gravado com um, buscado com o outro.
  it "hífen e apóstrofo (reto e tipográfico) valem espaço na chave, nos dois sentidos" do
    key = ->(name) { Patients::MatchKey.for(name, "1990-02-03") }
    expect(key.("Ana-Maria Souza")).to eq(key.("Ana Maria Souza"))
    expect(key.("D'Ávila Souza")).to eq(key.("D Ávila Souza"))
    expect(key.("D’Ávila Souza")).to eq(key.("D Avila Souza"))
    expect(key.("D‘Ávila Souza")).to eq(key.("D'Avila Souza"))
    expect(key.("Ana - Maria Souza")).to eq("ana maria souza|1990-02-03")
    expect(key.("D'Ávila Souza")).not_to eq(key.("Davila Souza"))

    hyphen = Patient.create!(cpf: valid_cpf(51), full_name: "Ana-Maria Souza", birth_date: "1990-02-03", sex: "female")
    spaced = Patient.create!(cpf: valid_cpf(52), full_name: "Ana Maria Souza", birth_date: "1990-02-04", sex: "female")
    expect(described_class.call(full_name: "Ana Maria Souza", birth_date: "1990-02-03")).to eq([ hyphen ])
    expect(described_class.call(full_name: "Ana-Maria Souza", birth_date: "1990-02-04")).to eq([ spaced ])

    apostrophe = Patient.create!(cpf: valid_cpf(53), full_name: "Joana D'Ávila", birth_date: "1990-02-05", sex: "female")
    split = Patient.create!(cpf: valid_cpf(54), full_name: "Joana D Ávila", birth_date: "1990-02-06", sex: "female")
    expect(described_class.call(full_name: "Joana D’Ávila", birth_date: "1990-02-05")).to eq([ apostrophe ])
    expect(described_class.call(full_name: "Joana D'Avila", birth_date: "1990-02-06")).to eq([ split ])
  end
end
