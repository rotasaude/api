require "rails_helper"

RSpec.describe Professionals::OpenLink do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:unit) { create_unit }
  let(:doctor) do
    Professional.create!(user: staff_with("medica@cidade.gov.br", "health_professional"), professional_name: "Helena",
                         council: "CRM", council_state: "PR", registration_number: "12345", cns: "700000000000005")
  end

  def open(**overrides)
    described_class.call(**{ professional: doctor, health_unit_id: unit.id, cbo_code: "225125", by: admin }.merge(overrides))
  end

  it "abre com início = agora e publica professional.linked só com ids" do
    travel_to(Time.zone.parse("2026-10-01 09:00")) do
      link = open.payload[:link]
      expect(link).to have_attributes(started_at: Time.current, started_by_user: admin, ended_at: nil)
      expect(DomainEvent.where(name: "professional.linked").sole.payload).to eq(
        "professional_link_id" => link.id, "professional_id" => doctor.id, "health_unit_id" => unit.id,
        "by_user_id" => admin.id
      )
    end
  end

  it "CBO fora da lista ou deprecated: invalid_cbo" do
    expect(open(cbo_code: "999999").reason).to eq(:invalid_cbo)
    deprecated = Professionals::Cbo::Entry.new(code: "225125", title: "x", council: "CRM", deprecated: true)
    allow(Professionals::Cbo).to receive(:find).with("225125").and_return(deprecated)
    expect(open.reason).to eq(:invalid_cbo)
  end

  it "CBO que exige outro conselho: council_mismatch; CBO sem conselho aceita" do
    expect(open(cbo_code: "223505").reason).to eq(:council_mismatch)
    expect(open(cbo_code: "515105")).to be_ok
  end

  it "unidade inativa ou inexistente: invalid_unit" do
    expect(open(health_unit_id: create_unit("UBS Fechada", active: false).id).reason).to eq(:invalid_unit)
    expect(open(health_unit_id: SecureRandom.uuid).reason).to eq(:invalid_unit)
  end

  it "unidade inativa E CBO inválido: invalid_unit" do
    inactive_unit = create_unit("UBS Fechada", active: false)
    expect(open(health_unit_id: inactive_unit.id, cbo_code: "999999").reason).to eq(:invalid_unit)
  end

  it "unidade inativa E conselho incoerente: invalid_unit" do
    inactive_unit = create_unit("UBS Fechada", active: false)
    expect(open(health_unit_id: inactive_unit.id, cbo_code: "223505").reason).to eq(:invalid_unit)
  end

  it "mesmo par ativo: already_linked; outro CBO na mesma unidade passa" do
    open
    expect(open.reason).to eq(:already_linked)
    expect(open(cbo_code: "225124")).to be_ok
  end
end
