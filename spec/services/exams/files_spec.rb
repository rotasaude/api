require "rails_helper"

RSpec.describe Exams::Files do
  include ActiveSupport::Testing::TimeHelpers

  before { exam_city! }

  let(:user) { staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier") }

  it "guarda PDF/JPEG/PNG pelos bytes mágicos e recusa o resto e o tamanho" do
    expect(described_class.store(bytes: ExamHelpers::PDF_BYTES, content_type: "application/pdf", user: user)).to be_ok
    png = "\x89PNG\r\n\x1A\n".b + "x" * 10
    expect(described_class.store(bytes: png, content_type: "image/png", user: user)).to be_ok
    expect(described_class.store(bytes: png, content_type: "application/pdf", user: user).reason).to eq(:invalid_file)
    expect(described_class.store(bytes: "MZ\x90\x00".b, content_type: "application/pdf", user: user).reason).to eq(:invalid_file)
    big = "%PDF-".b + ("a" * described_class::MAX_BYTES)
    expect(described_class.store(bytes: big, content_type: "application/pdf", user: user).reason).to eq(:invalid_file)
    expect(described_class.store_base64(data: "não é base64!", content_type: "application/pdf", user: user).reason).to eq(:invalid_file)
  end

  it "claim! só do mesmo autor e uma vez" do
    file = described_class.store(bytes: ExamHelpers::PDF_BYTES, content_type: "application/pdf", user: user).payload[:file]
    other = staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier")
    expect(described_class.claim!(file_id: file.id, user: other)).to be_nil
    expect(described_class.claim!(file_id: file.id, user: user)).to eq(file)
    expect(described_class.claim!(file_id: file.id, user: user)).to be_nil
  end

  it "URL curta: 5 min, só para o mesmo usuário e a mesma cidade" do
    file = pdf_file!(user: user)
    url = described_class.url_for(file, user: user)
    token = url.delete_prefix("/exams/files/")
    expect(described_class.resolve(token, user: user)).to eq(file)
    expect(described_class.resolve(token, user: municipal_admin!)).to be_nil
    travel 6.minutes do
      expect(described_class.resolve(token, user: user)).to eq(:expired)
    end
  end
end
