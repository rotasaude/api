require "rails_helper"

RSpec.describe Citizens::RejectErasure do
  before { Current.city = TEST_CITY_A }

  let(:verifier) { User.create!(email_address: "v-#{SecureRandom.hex(3)}@x.com", password: "secret123") }
  let(:admin) { User.create!(email_address: "a-#{SecureRandom.hex(3)}@x.com", password: "secret123") }
  let!(:pair) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  def raw_cpf_of(request)
    ApplicationRecord.connection.select_value(
      ApplicationRecord.sanitize_sql([ "SELECT cpf FROM citizen_erasure_requests WHERE id = ?", request.id ])
    )
  end

  let(:request) { Citizens::RequestErasure.call(cpf: "52998224725", document_checked: true, by: verifier).payload[:request] }

  it "recusa com motivo e não apaga nada" do
    expect(described_class.call(request: request, reason: "curto", by: admin).reason).to eq(:reason_too_short)
    # 10 caracteres só contam depois do strip.
    expect(described_class.call(request: request, reason: "   curto     ", by: admin).reason).to eq(:reason_too_short)
    expect(request.reload.status).to eq("pending")

    original_raw = raw_cpf_of(request)
    result = described_class.call(request: request, reason: "  documento com foto não confere  ", by: admin)

    expect(result.payload[:request]).to have_attributes(status: "rejected", decided_by_user_id: admin.id,
                                                        decided_at: be_present,
                                                        reject_reason: "documento com foto não confere")
    # O pedido recusado não guarda o CPF (marcador, como na confirmação), mas
    # segue ligado ao par apresentado.
    expect(raw_cpf_of(request)).not_to eq(original_raw)
    expect(CitizenErasureRequest.where(cpf: "52998224725")).to be_empty
    expect(result.payload[:request].reload.cpf).to start_with(Citizens::Erase::TOMBSTONE_PREFIX)
    expect(result.payload[:request].presented_citizen_id).to eq(pair.id)
    expect(pair.reload).to have_attributes(cpf: "52998224725", erased_at: nil)
    expect(DomainEvent.where(name: "citizen.erasure_rejected").last.payload).to eq("request_id" => request.id)
  end

  it "não decide de novo um pedido já decidido" do
    described_class.call(request: request, reason: "documento com foto não confere", by: admin)
    again = described_class.call(request: request.reload, reason: "outro motivo qualquer", by: admin)
    expect(again.reason).to eq(:not_pending)
    expect(request.reload.reject_reason).to eq("documento com foto não confere")
  end
end
