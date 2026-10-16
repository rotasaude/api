require "rails_helper"

# O api valida contra a CÓPIA do esquema publicado no contracts (FHIR:
# contracts 2598335, exams-v1.0.0; exam-order-v1: v1.1 do módulo 21b,
# contracts a595d5d, antes da tag exams-v1.1.0). Mudou o esquema lá: copie e
# troque os hashes aqui.
RSpec.describe "Cópias dos esquemas do contracts (exams-v1.1.0)" do
  it "as cópias são as publicadas" do
    expect(Digest::SHA256.file(Rails.root.join("config/exams/fhir-diagnostic-report-inbound.json")).hexdigest)
      .to eq("4ed964fb745d0fd396793f342b96dae2a44fcbe82d14aecbd61528ef80b62c22")
    expect(Digest::SHA256.file(Rails.root.join("spec/fixtures/exams/exam-order-v1.json")).hexdigest)
      .to eq("d9d64d504db4ca5224cd063138b6ec65646edc524b40bf98465a8f02f3f3d265")
  end
end
