require "rails_helper"

RSpec.describe Surveillance::Matcher do
  def disease(code, cid10: [], ciap2: [], local: false, **over)
    Surveillance::Disease.new(code: code, name: code.humanize, deadline: "weekly", cid10: cid10, ciap2: ciap2, repeat_after_days: 30,
                              sinan_form: nil, local: local, list_version: local ? nil : 1, notes: nil, id: nil, active: nil, **over)
  end

  let(:dengue) { disease("dengue", cid10: %w[A90]) }
  let(:tb) { disease("tuberculose", cid10: %w[A15 A16], ciap2: %w[A70]) }

  it "4 caracteres exato; 3 caracteres cobre a categoria; CIAP-2 exato; terminologia separada" do
    list = [ dengue, tb ]
    expect(described_class.disease_for("cid10", "A90", list)).to eq(dengue)
    expect(described_class.disease_for("cid10", "A169", list)).to eq(tb)
    expect(described_class.disease_for("cid10", "A16", list)).to eq(tb)
    expect(described_class.disease_for("cid10", "A91", list)).to be_nil
    expect(described_class.disease_for("ciap2", "A70", list)).to eq(tb)
    expect(described_class.disease_for("ciap2", "A90", list)).to be_nil
  end

  it "código de 4 caracteres da doença não cobre a categoria de 3" do
    febre = disease("febre_x", cid10: %w[A920])
    expect(described_class.disease_for("cid10", "A920", [ febre ])).to eq(febre)
    expect(described_class.disease_for("cid10", "A92", [ febre ])).to be_nil
    expect(described_class.disease_for("cid10", "A921", [ febre ])).to be_nil
  end

  it "terminologia desconhecida ou código vazio não corresponde" do
    expect(described_class.disease_for("loinc", "A90", [ dengue ])).to be_nil
    expect(described_class.disease_for("cid10", nil, [ dengue ])).to be_nil
    expect(described_class.disease_for("cid10", "", [ dengue ])).to be_nil
  end

  it "K12(d): código que casa na plataforma e numa local devolve a da plataforma, em qualquer ordem" do
    local = disease("local_dengue_pr", cid10: %w[A90], local: true)
    expect(described_class.disease_for("cid10", "A90", [ local, dengue ])).to eq(dengue)
    expect(described_class.disease_for("cid10", "A90", [ dengue, local ])).to eq(dengue)
    local_ciap = disease("local_tb_pr", ciap2: %w[A70], local: true)
    expect(described_class.disease_for("ciap2", "A70", [ local_ciap, tb ])).to eq(tb)
    expect(described_class.disease_for("cid10", "A90", [ local ])).to eq(local)
  end
end
