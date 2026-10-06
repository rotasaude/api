require "rails_helper"

# Contratos §5.3: reenviar só ficha recusada; a regra do uuid vem da prova
# técnica (pec_observations.yml → resend_uuid_policy, PROVISÓRIA: gate de
# go-live rotasaude/api#41).
RSpec.describe Ledi::Resend do
  include ActiveSupport::Testing::TimeHelpers

  let(:city) { ledi_ready!(register_test_city!, pec_url: "https://pec.a.test") }
  let(:by) { ledi_admin! }
  let(:entry) do
    allow(Ledi::DeliverJob).to receive(:perform_later)
    Ledi::Enqueue.call(Ledi::Fichas::Synthetic.new(cnes: "1234567", ine: "0000123456",
                                                   professional_cns: "700000000000005", cbo: "225142",
                                                   attended_at: Time.current), city: city)
  end

  before do
    entry.update!(status: "rejected", last_error: "CNES inválido", attempts: 1)
    allow(DomainEvents).to receive(:publish).and_call_original
  end

  it "mesmo uuid: volta a pending para agora, limpa o erro e dispara o envio" do
    allow(Ledi::Observations).to receive(:resend_uuid_policy).and_return(:same)
    uuid = entry.uuid
    freeze_time do
      described_class.call(entry: entry, by: by)
      expect(entry.reload.slice(:status, :uuid, :last_error, :next_attempt_at))
        .to eq("status" => "pending", "uuid" => uuid, "last_error" => nil, "next_attempt_at" => Time.current)
    end
    expect(Ledi::DeliverJob).to have_received(:perform_later).twice
  end

  it "uuid novo: troca no transporte e na ficha" do
    allow(Ledi::Observations).to receive(:resend_uuid_policy).and_return(:new)
    old = entry.uuid
    described_class.call(entry: entry, by: by)
    entry.reload
    expect(entry.uuid).not_to eq(old)
    expect(entry.uuid).to start_with("1234567-")
    expect(Ledi::Transport.read(entry.bytes).uuidDadoSerializado).to eq(entry.uuid)
  end

  it "reinicia a janela de tentativas: first_attempt_at volta a nil e um erro transitório não vira failed" do
    allow(Ledi::Observations).to receive(:resend_uuid_policy).and_return(:same)
    entry.update_columns(first_attempt_at: 3.days.ago)
    described_class.call(entry: entry, by: by)
    expect(entry.reload.first_attempt_at).to be_nil
    entry.retry_later!(error: "timeout", wait: 60, give_up_after: 24.hours)
    expect(entry.reload.status).to eq("pending")
  end

  it "publica ledi.ficha_resent só com ids" do
    allow(Ledi::Observations).to receive(:resend_uuid_policy).and_return(:same)
    described_class.call(entry: entry, by: by)
    expect(DomainEvents).to have_received(:publish).with("ledi.ficha_resent", outbox_id: entry.id, user_id: by.id)
  end

  it "ficha que não está recusada: NotRejected, sem evento nem envio" do
    entry.update_columns(status: "pending")
    expect { described_class.call(entry: entry.reload, by: by) }.to raise_error(described_class::NotRejected)
    expect(DomainEvents).not_to have_received(:publish).with("ledi.ficha_resent", anything)
  end
end
