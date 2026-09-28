require "rails_helper"

RSpec.describe HealthUnit, "endereço (ADR 0023)" do
  def unit(**attrs) = described_class.new({ name: "UBS Centro", kind: "ubs" }.merge(attrs))

  it "normaliza texto e CEP; vazio vira nil" do
    u = unit(address_street: "  Rua XV  de Novembro ", address_number: " 500 ", address_complement: "",
             address_zip: "80020-310")
    expect(u).to be_valid
    expect(u).to have_attributes(address_street: "Rua XV de Novembro", address_number: "500",
                                 address_complement: nil, address_zip: "80020310")
    expect(unit(address_zip: "").address_zip).to be_nil
  end

  it "recusa CEP fora de 8 dígitos e texto acima do limite" do
    { address_zip: "8002031", address_street: "x" * 161, address_number: "1" * 21, address_complement: "c" * 81 }
      .each do |field, value|
        u = unit(field => value)
        expect(u).not_to be_valid, field.to_s
        expect(u.errors.attribute_names).to include(field)
      end
    expect(unit(address_zip: "8002031a")).not_to be_valid
  end
end
