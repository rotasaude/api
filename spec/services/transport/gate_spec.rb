require "rails_helper"

RSpec.describe Transport::Gate do
  it "sanitary_transport sem pré-requisito; tfd exige sanitary_transport e clinical_record utilizáveis" do
    city = clinical_city!
    Platform::Features.set!(city: city, key: "tfd", enabled: true, maintainer: ledi_maintainer!)
    expect(Platform::Features.missing(city, "tfd")).to eq([ "sanitary_transport_disabled" ])
    expect(Platform::Features.missing(city, "sanitary_transport")).to eq([])
    Platform::Features.set!(city: city, key: "sanitary_transport", enabled: true, maintainer: ledi_maintainer!)
    expect(Tfd::Gate.usable?(city)).to be(true)
    expect(Transport::Gate.usable?(city)).to be(true)
    city.update!(record_mode: "integrated")
    expect(Platform::Features.missing(city, "tfd")).to include("clinical_record_disabled")
  end

  it "desligar o transporte não desliga o tfd: continua ligado, mas não utilizável (T21)" do
    city = transport_city!(tfd: true)
    expect(Tfd::Gate.usable?(city)).to be(true)
    Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
    expect(Tfd::Gate.enabled?(city)).to be(true)
    expect(Tfd::Gate.usable?(city)).to be(false)
    expect(Platform::Features.missing(city, "tfd")).to eq([ "sanitary_transport_disabled" ])
  end

  it "cidade nula ou sem id nunca é utilizável" do
    expect([ described_class.usable?(nil), described_class.enabled?(nil), Tfd::Gate.usable?(nil) ]).to eq([ false, false, false ])
  end
end

RSpec.describe "Portões e papéis do transporte" do
  it "TfdGate responde 403 feature_disabled com o transporte desligado" do
    city = transport_city!(tfd: true)
    Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
    controller = Class.new(ActionController::API) do
      include ::TfdGate
      def probe = require_tfd!
    end.new
    allow(Current).to receive(:city).and_return(city)
    rendered = nil
    allow(controller).to receive(:render) { |**opts| rendered = opts }
    controller.probe
    expect(rendered).to eq(json: { error: "feature_disabled", feature: "tfd" }, status: :forbidden)
  end

  it "Access: central e comissão pela Membership ativa; motorista só com Membership driver E TransportDriver ativo" do
    transport_city!
    dispatcher = staff_with("c-#{SecureRandom.hex(2)}@cidade.gov.br", "transport_dispatcher")
    expect([ Transport::Access.dispatcher?(dispatcher), Transport::Access.committee?(dispatcher) ]).to eq([ true, false ])
    driver = driver_user!
    expect(Transport::Access.driver_for(driver)).to be_a(TransportDriver)
    driver.transport_driver.update!(active: false)
    expect(Transport::Access.driver_for(driver)).to be_nil
    driver.transport_driver.update!(active: true)
    driver.memberships.update_all(revoked_at: Time.current)
    expect(Transport::Access.driver_for(driver)).to be_nil
    expect(Transport::Access.driver_for(nil)).to be_nil
  end
end
