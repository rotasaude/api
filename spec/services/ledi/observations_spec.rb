# spec/services/ledi/observations_spec.rb
require "rails_helper"

RSpec.describe Ledi::Observations do
  after { described_class.reload! }

  def with_file(yaml)
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(described_class::PATH).and_return(yaml)
    described_class.reload!
  end

  it "lê o arquivo da prova técnica" do
    expect(described_class::PATH).to eq(Rails.root.join("config/ledi/pec_observations.yml"))
    expect(described_class.session_expired_statuses).to all(be_an(Integer))
    expect(%i[same new]).to include(described_class.resend_uuid_policy)
  end

  it "duplicidade e política de reenvio vêm do que foi observado" do
    with_file(<<~YAML)
      duplicate_after_accept: { status: 400, marker: "já recebida" }
      resend_after_rejection: { same_uuid: rejected }
      session_expired_statuses: [401, 302]
    YAML
    expect(described_class.duplicate_marker).to eq("já recebida")
    expect(described_class.resend_uuid_policy).to eq(:new)
    expect(described_class.session_expired_statuses).to eq([ 401, 302 ])
  end

  it "reenvio após 2xx sem marcador e mesmo uuid aceito" do
    with_file(<<~YAML)
      duplicate_after_accept: { status: 201, marker: null }
      resend_after_rejection: { same_uuid: accepted }
      session_expired_statuses: [401]
    YAML
    expect(described_class.duplicate_marker).to be_nil
    expect(described_class.resend_uuid_policy).to eq(:same)
  end
end
