require "rails_helper"

# Módulo 35b (ADR 0054; contrato §1, Q10, Q11; plano, Valor fixado 1): o
# centro de zoonoses é utilizável com a chave ligada e o cadastro territorial
# utilizável; o casa a casa e o app pedem também a visita domiciliar; as
# chaves da ouvidoria pedem a ouvidoria (Q10). Sem cascata para o
# vector_control; as peças do 35a abrem com um dos dois (Q11).
RSpec.describe Zoonoses::Gate, type: :model do
  def set!(city, key, enabled) = Platform::Features.set!(city: city, key: key, enabled: enabled, maintainer: ledi_maintainer!)

  it "ligado com o cadastro territorial desligado → usable? false" do
    city = zoonoses_city!
    expect(described_class.usable?(city)).to be(true)
    set!(city, TerritoryRegistry::Gate::KEY, false)
    expect(Platform::Features.enabled?(city, described_class::KEY)).to be(true)
    expect(Platform::Features.missing(city, described_class::KEY)).to eq(%w[territory_registry_disabled])
    expect(described_class.usable?(city)).to be(false)
    expect(described_class.field_usable?(city)).to be(false)
  end

  it "desligado → usable? false; cidade nula ou sem id → false" do
    city = home_visit_city!
    expect(described_class.usable?(city)).to be(false)
    expect(described_class.usable?(nil)).to be(false)
    expect(described_class.usable?(City.new)).to be(false)
  end

  it "usable? sem home_visits → true e field_usable? false" do
    city = registry_city!
    set!(city, described_class::KEY, true)
    expect(described_class.usable?(city)).to be(true)
    expect(described_class.field_usable?(city)).to be(false)
    set!(city, HomeVisits::Gate::KEY, true)
    expect(described_class.field_usable?(city)).to be(true)
  end

  it "vector_control desligado não muda nada (sem cascata)" do
    city = vector_city!
    set!(city, described_class::KEY, true)
    expect([ described_class.usable?(city), described_class.field_usable?(city) ]).to eq([ true, true ])
    set!(city, VectorControl::Gate::KEY, false)
    expect([ described_class.usable?(city), described_class.field_usable?(city) ]).to eq([ true, true ])
  end

  it "VectorControl::Gate.supplies_usable? com só um dos dois → true; sem os dois → false" do
    city = vector_city!
    expect(VectorControl::Gate.supplies_usable?(city)).to be(true)
    set!(city, VectorControl::Gate::KEY, false)
    expect(VectorControl::Gate.supplies_usable?(city)).to be(false)
    set!(city, described_class::KEY, true)
    expect(VectorControl::Gate.usable?(city)).to be(false)
    expect(VectorControl::Gate.supplies_usable?(city)).to be(true)
    expect(VectorControl::Gate.supplies_usable?(nil)).to be(false)
  end

  it "ombudsman_usable? sem a ouvidoria → false" do
    city = zoonoses_city!
    expect(described_class.ombudsman_usable?(city)).to be(false)
    set!(city, Ombudsman::Gate::KEY, true)
    expect(described_class.ombudsman_usable?(city)).to be(true)
    set!(city, described_class::KEY, false)
    expect(described_class.ombudsman_usable?(city)).to be(false)
  end

  # O concern das rotas /zoonoses (Task 5 em diante): 403 com a chave.
  describe ZoonosesGate do
    let(:host) do
      Class.new do
        include ZoonosesGate

        attr_reader :rendered

        def render(**args) = (@rendered = args)
        def check! = require_zoonoses!
      end.new
    end

    it "require_zoonoses! responde 403 feature_disabled com a chave quando o gate fecha" do
      zoonoses_city!
      allow(Current).to receive(:city).and_return(nil)
      host.check!
      expect(host.rendered).to eq(json: { error: "feature_disabled", feature: "zoonoses" }, status: :forbidden)
    end

    it "deixa passar com o gate aberto" do
      city = zoonoses_city!
      allow(Current).to receive(:city).and_return(city)
      host.check!
      expect(host.rendered).to be_nil
    end
  end
end
