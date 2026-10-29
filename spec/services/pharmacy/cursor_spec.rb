require "rails_helper"

# Módulo 27a (ADR 0045): cursor opaco das listas da farmácia.
RSpec.describe Pharmacy::Cursor do
  let(:parts) { [ "2026-10-29T12:00:00.123456Z", SecureRandom.uuid ] }

  it "ida e volta" do
    expect(described_class.decode(described_class.encode(parts))).to eq(parts)
  end

  it "é base64 url-safe, sem padding" do
    encoded = described_class.encode(parts)
    expect(encoded).to match(/\A[A-Za-z0-9_-]+\z/)
  end

  it "inválido → nil, sem exceção" do
    [ nil, "", 5, "não é base64!", "e30", Base64.urlsafe_encode64("[1,2]"), Base64.urlsafe_encode64("[]"),
      Base64.urlsafe_encode64('["a","b","c","d","e"]'), Base64.urlsafe_encode64("[not json"), "a" * 513 ].each do |raw|
      expect(described_class.decode(raw)).to be_nil, "esperava nil para #{raw.inspect}"
    end
  end
end
