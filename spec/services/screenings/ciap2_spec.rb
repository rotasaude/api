# spec/services/screenings/ciap2_spec.rb
require "rails_helper"

RSpec.describe Screenings::Ciap2 do
  before { ciap2_release! }

  it "acha o código da release ativa, com rótulo e release; desconhecido é nil" do
    code = described_class.find("k86")
    expect([ code.code, code.label ]).to eq([ "K86", "Hipertensão sem complicações" ])
    expect(code.release_id).to eq(TerminologyRelease.active.find_by!(kind: "ciap2").id)
    expect(described_class.find("Z99")).to be_nil
    expect(described_class.find(nil)).to be_nil
    expect(described_class.label("K86", code.release_id)).to eq("Hipertensão sem complicações")
  end

  it "busca por código ou por nome, sem acento e sem caixa, até o limite" do
    expect(described_class.search("tos").map(&:code)).to eq([ "R05" ])
    expect(described_class.search("hipertensao").map(&:code)).to eq([ "K86" ])
    expect(described_class.search("k8").map(&:code)).to eq([ "K86" ])
    expect(described_class.search("").map(&:code)).to eq([])
    expect(described_class.search("e", limit: 2).size).to eq(2)
  end
end
