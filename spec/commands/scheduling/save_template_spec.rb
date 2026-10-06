require "rails_helper"

RSpec.describe Scheduling::SaveTemplate do
  before { Current.city = TEST_CITY_A; ensure_appointment_types! }
  after { Current.reset }

  let(:admin) { staff_with("admin-modelos@cidade.gov.br", "municipal_admin") }
  let(:blocks) { [ { "starts" => "09:00", "ends" => "11:00", "kind" => "bookable", "appointment_type_key" => "consulta_medica" } ] }

  it "cria com limite padrão 2, edita parcialmente e publica só ids" do
    template = described_class.call(attrs: { "name" => " Manhã ", "blocks" => blocks }, by: admin).payload[:template]
    expect(template).to have_attributes(name: "Manhã", fit_in_limit: 2, active: true, blocks: blocks)
    described_class.call(template: template, attrs: { "fit_in_limit" => 0, "active" => false }, by: admin)
    expect(template.reload).to have_attributes(fit_in_limit: 0, active: false, blocks: blocks)
    expect(DomainEvent.where(name: "schedule_template.changed").pluck(:payload).uniq)
      .to eq([ { "template_id" => template.id, "user_id" => admin.id } ])
  end

  it "recusa nome, limite, faixas e ativo inválidos sem gravar" do
    expect(described_class.call(attrs: { "name" => "", "blocks" => blocks }, by: admin).reason).to eq(:invalid_name)
    expect(described_class.call(attrs: { "name" => "M", "fit_in_limit" => 21, "blocks" => blocks }, by: admin).reason)
      .to eq(:invalid_fit_in_limit)
    result = described_class.call(attrs: { "name" => "M", "blocks" => [] }, by: admin)
    expect([ result.reason, result.details ]).to eq([ :invalid_blocks, { detail: "empty" } ])
    expect(described_class.call(attrs: { "name" => "M", "blocks" => blocks, "active" => "sim" }, by: admin).reason).to eq(:invalid)
    expect(ScheduleTemplate.count).to eq(0)
  end
end
