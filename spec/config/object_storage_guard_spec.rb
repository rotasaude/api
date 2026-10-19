require "rails_helper"

RSpec.describe ObjectStorage do
  let(:full) { { "MINIO_ENDPOINT" => "http://m:9000", "MINIO_BUCKET" => "b", "MINIO_ACCESS_KEY_ID" => "k", "MINIO_SECRET_ACCESS_KEY" => "s" } }
  it("passa com as quatro em produção") { expect { described_class.check!(env: full, rails_env: "production") }.not_to raise_error }
  it "falha em produção e staging se faltar uma" do
    %w[production staging].each do |e|
      expect { described_class.check!(env: full.except("MINIO_BUCKET"), rails_env: e) }
        .to raise_error(ObjectStorage::MissingConfig, /MINIO_BUCKET/)
    end
  end
  it("não exige nada em development e test") { expect { described_class.check!(env: {}, rails_env: "development") }.not_to raise_error }
end
