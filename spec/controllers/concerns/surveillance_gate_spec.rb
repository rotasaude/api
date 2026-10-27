require "rails_helper"

# Módulo 25 (ADR 0043): o 403 de cada rota diz qual interruptor falta.
RSpec.describe SurveillanceGate do
  let(:host) do
    Class.new do
      include SurveillanceGate
      attr_reader :rendered

      def render(json:, status:) = (@rendered = [ json, status ])
      public :require_surveillance!, :require_surveillance_consultation!
    end.new
  end
  let(:city) { clinical_city!(record_mode: "integrated", enabled: false) }

  before { allow(Current).to receive(:city).and_return(city) }

  it "interruptor desligado: 403 feature_disabled surveillance, nas duas guardas" do
    host.require_surveillance!
    expect(host.rendered).to eq([ { error: "feature_disabled", feature: "surveillance" }, :forbidden ])
    host.require_surveillance_consultation!
    expect(host.rendered).to eq([ { error: "feature_disabled", feature: "surveillance" }, :forbidden ])
  end

  it "ligado sem prontuário: a rota comum passa; a de consulta aponta clinical_record" do
    Platform::Features.set!(city: city, key: "surveillance", enabled: true, maintainer: ledi_maintainer!)
    host.require_surveillance!
    expect(host.rendered).to be_nil
    host.require_surveillance_consultation!
    expect(host.rendered).to eq([ { error: "feature_disabled", feature: "clinical_record" }, :forbidden ])
  end

  it "ligado com o prontuário utilizável: as duas passam" do
    Platform::Features.set!(city: city, key: "surveillance", enabled: true, maintainer: ledi_maintainer!)
    clinical_city!
    allow(Current).to receive(:city).and_return(city.reload)
    host.require_surveillance_consultation!
    expect(host.rendered).to be_nil
  end
end
