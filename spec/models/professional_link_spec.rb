require "rails_helper"

RSpec.describe ProfessionalLink do
  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:unit) { create_unit }
  let(:professional) do
    Professional.create!(user: staff_with("medica@cidade.gov.br", "health_professional"), professional_name: "Helena",
                         council: "CRM", council_state: "PR", registration_number: "12345", cns: "700000000000005")
  end

  it "recusa CBO fora do catálogo na criação" do
    link = described_class.new(professional: professional, health_unit: unit, cbo_code: "999999",
                               started_at: Time.current, started_by_user: admin)
    expect(link).not_to be_valid
    expect(link.errors.attribute_names).to include(:cbo_code)
  end

  it "aceita CBO conhecido na criação" do
    link = described_class.new(professional: professional, health_unit: unit, cbo_code: "225125",
                               started_at: Time.current, started_by_user: admin)
    expect(link).to be_valid
  end
end
