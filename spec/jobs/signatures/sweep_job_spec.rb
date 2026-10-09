# spec/jobs/signatures/sweep_job_spec.rb
require "rails_helper"

# Desvio 8 (spec §3): desligado o interruptor (ou o prontuário, ou o modo de
# prontuário), pendentes voltam ao papel com feature_disabled; o assinado
# continua; sessões vencidas e states velhos são limpos.
RSpec.describe Signatures::SweepJob do
  before { Current.city = signature_city! }
  after { Current.reset }

  let(:doctor) { signer_doctor!(create_unit) }

  it "desligado: pendentes ao papel; o resto intacto; sessões e states" do
    certificate = linked_certificate!(doctor)
    pending = signature_request!(author: doctor)
    signed = signature_request!(author: doctor, status: "signed")
    signature_session!(doctor, certificate: certificate, started_at: 12.hours.ago, expires_at: 1.hour.ago)
    old_state = Signatures::OauthStates.issue!(user: doctor, purpose: "link", provider: "vidaas", now: 2.days.ago).row
    fresh_state = Signatures::OauthStates.issue!(user: doctor, purpose: "link", provider: "vidaas").row

    described_class.perform_now
    expect(pending.reload.status).to eq("pending") # ligado: nada muda na fila
    expect(SignatureSession.where(user_id: doctor.id).pluck(:status)).to eq([ "expired" ])
    expect(SignatureOauthState.exists?(old_state.id)).to be(false)
    expect(SignatureOauthState.exists?(fresh_state.id)).to be(true)

    signature_city!(enabled: false)
    described_class.perform_now
    expect(pending.reload).to have_attributes(status: "returned_to_paper", reason_code: "feature_disabled")
    expect(signed.reload.status).to eq("signed")
    expect(DomainEvent.where(name: "signature.returned_to_paper").sole.payload)
      .to eq("request_id" => pending.id, "reason_code" => "feature_disabled")
  end

  it "prontuário desligado (digital_signature ligado): pendentes ao papel" do
    pending = signature_request!(author: doctor)
    clinical_city!(enabled: false)
    described_class.perform_now
    expect(pending.reload).to have_attributes(status: "returned_to_paper", reason_code: "feature_disabled")
  end

  it "modo de prontuário fora de record: pendentes ao papel" do
    pending = signature_request!(author: doctor)
    clinical_city!(record_mode: "integrated")
    described_class.perform_now
    expect(pending.reload).to have_attributes(status: "returned_to_paper", reason_code: "feature_disabled")
  end

  it "agendado a cada 10 minutos em toda cidade (config/recurring.yml)" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "signature_sweep")
    expect(entry).to eq("class" => "Signatures::SweepJob", "queue" => "housekeeping", "schedule" => "every 10 minutes")
    expect(described_class.ancestors).to include(EachCityJob)
  end
end
