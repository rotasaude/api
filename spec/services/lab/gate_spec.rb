require "rails_helper"

# ADR 0037: os três interruptores, em cadeia (exam_tracking → municipal_lab →
# lab_hl7_inbound → fake_middleware), e o simulado só fora de produção.
RSpec.describe Lab::Gate do
  let(:maintainer) { ledi_maintainer! }
  let(:city) { exam_city! }

  def set(key, on) = Platform::Features.set!(city: city, key: key, enabled: on, maintainer: maintainer)

  it "liga em cadeia e diz o que falta" do
    set("municipal_lab", true)
    expect(described_class.usable?(city)).to be(true)
    set("lab_hl7_inbound", true)
    set("fake_middleware", true)
    expect(described_class.fake_middleware_usable?(city)).to be(true)
    set("exam_tracking", false)
    expect(described_class.usable?(city)).to be(false)
    expect(Platform::Features.missing(city, "municipal_lab")).to eq([ "exam_tracking_disabled" ])
    expect(Platform::Features.missing(city, "lab_hl7_inbound")).to eq([ "municipal_lab_disabled" ])
    expect(Platform::Features.missing(city, "fake_middleware")).to eq([ "lab_hl7_inbound_disabled" ])
  end

  it "fake_middleware não existe em produção" do
    expect(Platform::Features.find("fake_middleware", env: "production")).to be_nil
    expect(described_class.fake_middleware_usable?(city, env: "production")).to be(false)
    expect { Platform::Features.set!(city: city, key: "fake_middleware", enabled: true, maintainer: maintainer, env: "production") }
      .to raise_error(Platform::Features::UnknownFeature)
  end

  it "cidade nula ou sem id nunca é utilizável" do
    expect(described_class.usable?(nil)).to be(false)
    expect(described_class.hl7_usable?(City.new)).to be(false)
  end

  # ADR 0038: qualidade e estoque, independentes entre si, ambos sobre municipal_lab.
  it "lab_quality_control e lab_inventory dependem de municipal_lab e não um do outro" do
    set("municipal_lab", true)
    set("lab_quality_control", true)
    expect(described_class.qc_usable?(city)).to be(true)
    expect(described_class.inventory_usable?(city)).to be(false)
    set("lab_inventory", true)
    expect(described_class.inventory_usable?(city)).to be(true)
    set("lab_quality_control", false)
    expect(described_class.inventory_usable?(city)).to be(true)
    set("municipal_lab", false)
    expect(described_class.inventory_usable?(city)).to be(false)
    expect(Platform::Features.missing(city, "lab_quality_control")).to eq([ "municipal_lab_disabled" ])
    expect(Platform::Features.missing(city, "lab_inventory")).to eq([ "municipal_lab_disabled" ])
    expect(described_class.qc_usable?(nil)).to be(false)
  end
end
