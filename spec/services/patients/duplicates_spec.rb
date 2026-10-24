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
end
