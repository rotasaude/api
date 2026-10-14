require "rails_helper"

# O api valida contra a CÓPIA do esquema publicado no contracts (tag
# exams-v1.0.0, contracts d7f8ce7). Mudou o esquema lá: copie e troque os
# hashes aqui.
RSpec.describe "Cópias dos esquemas do contracts (exams-v1.0.0)" do
  it "as cópias são as publicadas" do
    expect(Digest::SHA256.file(Rails.root.join("config/exams/fhir-diagnostic-report-inbound.json")).hexdigest)
      .to eq("4ed964fb745d0fd396793f342b96dae2a44fcbe82d14aecbd61528ef80b62c22")
    expect(Digest::SHA256.file(Rails.root.join("spec/fixtures/exams/exam-order-v1.json")).hexdigest)
      .to eq("2c1d4f1bf33910adbe4ad75bf77d174d4f353c8b3eb7055b6b067323484e92c6")
  end
end
