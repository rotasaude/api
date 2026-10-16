require "rails_helper"

# O api valida contra a CÓPIA do esquema publicado no contracts (FHIR:
# contracts 2598335, exams-v1.0.0; exam-order-v1: v1.1 do módulo 21b,
# contracts 8f83d7d, antes da tag exams-v1.1.0). Mudou o esquema lá: copie e
# troque os hashes aqui.
RSpec.describe "Cópias dos esquemas do contracts (exams-v1.1.0)" do
  it "as cópias são as publicadas" do
    expect(Digest::SHA256.file(Rails.root.join("config/exams/fhir-diagnostic-report-inbound.json")).hexdigest)
      .to eq("4ed964fb745d0fd396793f342b96dae2a44fcbe82d14aecbd61528ef80b62c22")
    expect(Digest::SHA256.file(Rails.root.join("spec/fixtures/exams/exam-order-v1.json")).hexdigest)
      .to eq("7c961613a24ccb06ec05d48b16e280aa02c543edf6c1d70de08476432f9d8014")
  end
end
