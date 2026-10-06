require "rails_helper"

# ADR 0029 §3.1; contratos §3, §9: a cidade cria, ajusta e desativa; o tipo da
# plataforma não troca os grupos de CBO.
RSpec.describe Scheduling::SaveAppointmentType do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:admin) { staff_with("admin-tipos@cidade.gov.br", "municipal_admin") }
  let(:valid) { { "key" => "acupuntura", "name" => "Acupuntura", "duration_minutes" => 30, "cbo_prefixes" => ["2251", "2236"] } }

  it "cria tipo da cidade, com evento só de key e usuário" do
    type = described_class.create(attrs: valid, by: admin).payload[:type]
    expect(type).to have_attributes(key: "acupuntura", origin: "city", active: true, cbo_prefixes: ["2251", "2236"])
    expect(DomainEvent.where(name: "appointment_type.changed").last.payload).to eq("key" => "acupuntura", "user_id" => admin.id)
  end

  {
    { "key" => "Acupuntura" } => :invalid_key, { "key" => "a" } => :invalid_key, { "key" => nil } => :invalid_key,
    { "name" => "" } => :invalid_name, { "name" => "x" * 61 } => :invalid_name,
    { "duration_minutes" => 4 } => :invalid_duration, { "duration_minutes" => 241 } => :invalid_duration,
    { "duration_minutes" => "30" } => :invalid_duration,
    { "cbo_prefixes" => [] } => :invalid_cbo_prefixes, { "cbo_prefixes" => ["22a1"] } => :invalid_cbo_prefixes,
    { "cbo_prefixes" => ["1234567"] } => :invalid_cbo_prefixes, { "cbo_prefixes" => Array.new(21, "2251") } => :invalid_cbo_prefixes,
    { "cbo_prefixes" => "2251" } => :invalid_cbo_prefixes, { "active" => "sim" } => :invalid
  }.each do |change, reason|
    it "recusa #{change.inspect} com #{reason}" do
      expect(described_class.create(attrs: valid.merge(change), by: admin).reason).to eq(reason)
      expect(AppointmentType.where(key: "acupuntura")).to be_empty
    end
  end

  it "key repetida (inclusive da plataforma) é key_taken" do
    described_class.create(attrs: valid, by: admin)
    expect(described_class.create(attrs: valid, by: admin).reason).to eq(:key_taken)
    expect(described_class.create(attrs: valid.merge("key" => "retorno"), by: admin).reason).to eq(:key_taken)
  end

  it "ajusta duração, nome e ativo do tipo da plataforma; grupos de CBO travados" do
    medica = AppointmentType.find_by!(key: "consulta_medica")
    result = described_class.update(type: medica, attrs: { "duration_minutes" => 30, "active" => false, "name" => "Consulta" }, by: admin)
    expect(result.payload[:type]).to have_attributes(duration_minutes: 30, active: false, name: "Consulta", origin: "platform")
    expect(DomainEvent.where(name: "appointment_type.changed").last.payload).to eq("key" => "consulta_medica", "user_id" => admin.id)
    expect(described_class.update(type: medica, attrs: { "cbo_prefixes" => ["2251"] }, by: admin).reason).to eq(:platform_type_locked)
    expect(medica.reload.cbo_prefixes).to eq(["2251", "2252", "2253"])
  end

  it "edição inválida não grava nada" do
    medica = AppointmentType.find_by!(key: "consulta_medica")
    expect(described_class.update(type: medica, attrs: { "name" => "Nova", "duration_minutes" => 500 }, by: admin).reason)
      .to eq(:invalid_duration)
    expect(medica.reload).to have_attributes(name: "Consulta médica", duration_minutes: 20)
  end

  it "tipo da cidade troca os grupos de CBO" do
    type = described_class.create(attrs: valid, by: admin).payload[:type]
    expect(described_class.update(type: type, attrs: { "cbo_prefixes" => ["2235"] }, by: admin).payload[:type].cbo_prefixes)
      .to eq(["2235"])
  end
end
