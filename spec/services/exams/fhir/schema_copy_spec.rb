require "rails_helper"

# O api valida contra a CÓPIA do esquema publicado no contracts (contracts
# f3d881a, antes da tag exams-v1.0.0). Mudou o esquema lá: copie e troque os
# hashes aqui.
RSpec.describe "Cópias dos esquemas do contracts (exams-v1.0.0)" do
  it "as cópias são as publicadas" do
    expect(Digest::SHA256.file(Rails.root.join("config/exams/fhir-diagnostic-report-inbound.json")).hexdigest)
      .to eq("4ed964fb745d0fd396793f342b96dae2a44fcbe82d14aecbd61528ef80b62c22")
    expect(Digest::SHA256.file(Rails.root.join("spec/fixtures/exams/exam-order-v1.json")).hexdigest)
      .to eq("2f0914eeda47c91575e7fb95964adcac2383e04815ccdd7c39541ef239b37cb6")
  end
end
