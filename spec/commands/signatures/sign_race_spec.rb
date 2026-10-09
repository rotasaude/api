# spec/commands/signatures/sign_race_spec.rb
require "rails_helper"

# Review Focus 1 (ADR 0032, invariante "nenhum documento é assinado duas
# vezes"): job e lote sobre o MESMO pedido, em conexões reais. Quem chega
# segundo pula o pedido (SKIP LOCKED) sem esperar a chamada ao PSC do outro;
# o vencedor grava a assinatura e o pedido signed juntos. A volta ao papel
# (FOR UPDATE) espera o job e vê o resultado; espera longa vira not_pending.
RSpec.describe "Corrida job × lote" do
  self.use_transactional_tests = false

  let(:city) { TEST_CITY_A }
  let(:entered) { Queue.new }
  let(:release) { Queue.new }
  let(:calls) { Queue.new }
  let(:threads) { [] }

  before do
    allow(Signatures::Gate).to receive(:usable?).and_return(true)
    allow(Signatures::CertificateRules).to receive(:reason).and_return(nil)
    allow(Signatures::Signing).to receive(:call) do |requests:, certificate:, **|
      calls << requests.map(&:id)
      entered << true
      release.pop(timeout: 5)
      # Como o Signing real: assinatura e pedido signed na mesma gravação.
      signed = requests.map do |request|
        signature_row!(request, certificate: certificate).tap do
          request.update!(status: "signed", reason_code: nil, resolved_at: Time.current)
        end
      end
      Signatures::Signing::Outcome.new(signed: signed, failed: [])
    end
    @rows = CityConnection.with(city) do
      user = User.create!(email_address: "corrida-#{SecureRandom.hex(4)}@cidade.gov.br", password: "senha-segura-123")
      certificate = linked_certificate!(user, leaf: test_pki.leaf_for(SignatureHelpers::DOCTOR_CPF))
      session = signature_session!(user, certificate: certificate)
      request = signature_request!(author: user)
      { user: user, certificate: certificate, session: session, request: request }
    end
  end

  after do
    3.times { release << true }
    threads.each { |thread| (thread.join(5) rescue nil) || thread.kill } # thread que levantou não pula a limpeza
    CityConnection.with(city) do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        Signature.where(signature_request_id: @rows[:request].id).delete_all
        SignatureRequest.where(id: @rows[:request].id).delete_all
        SignatureSession.where(id: @rows[:session].id).delete_all
        SignerCertificate.where(id: @rows[:certificate].id).delete_all
        DomainEvent.where("payload->>'request_id' = ?", @rows[:request].id).delete_all
        User.where(id: @rows[:user].id).delete_all
      end
    end
  end

  def in_city(&block) = track(Thread.new { CityConnection.with(city) { ApplicationRecord.transaction(&block) } })
  def track(thread) = thread.tap { threads << thread }

  def job = in_city { Signatures::SignPending.call(request_id: @rows[:request].id) }

  def batch
    token = Signatures::Psc::Token.new(access_token: "t", expires_in: 300, scope: "multi_signature")
    track(Thread.new do
      CityConnection.with(city) { Signatures::RunBatch.call(user: @rows[:user], request_ids: [ @rows[:request].id ], token: token) }
    end)
  end

  def stored
    CityConnection.with(city) do
      [ SignatureRequest.find(@rows[:request].id).status, Signature.where(signature_request_id: @rows[:request].id).count ]
    end
  end

  it "job primeiro: o lote pula sem esperar; uma assinatura só" do
    first = job
    expect(entered.pop(timeout: 5)).to be(true)
    second = batch
    expect(second.join(5)).to be_truthy
    expect(first).to be_alive # o lote terminou com o job ainda dentro do PSC
    expect(second.value.payload[:record]).to eq(signed: 0, failed: [])
    release << true
    expect(first.value).to eq(:signed)
    expect(calls.size).to eq(1)
    expect(stored).to eq([ "signed", 1 ])
  end

  it "lote primeiro: o job pula sem esperar; uma assinatura só" do
    first = batch
    expect(entered.pop(timeout: 5)).to be(true)
    second = job
    expect(second.join(5)).to be_truthy
    expect(first).to be_alive
    expect(second.value).to eq(:skipped)
    release << true
    expect(first.value.payload[:record]).to eq(signed: 1, failed: [])
    expect(calls.size).to eq(1)
    expect(stored).to eq([ "signed", 1 ])
  end

  it "volta ao papel com o job em voo: espera o job e vê signed (not_pending)" do
    first = job
    expect(entered.pop(timeout: 5)).to be(true)
    back = track(Thread.new do
      CityConnection.with(city) do
        Signatures::ReturnToPaper.call(request_id: @rows[:request].id, by: @rows[:user], reason: "sem certificado hoje")
      end
    end)
    expect(wait_for_lock_wait).to be(true) # espera o FOR UPDATE do job
    release << true
    expect(first.value).to eq(:signed)
    expect(back.value.reason).to eq(:not_pending)
    expect(stored).to eq([ "signed", 1 ])
  end

  it "volta ao papel com o job preso no PSC além do lock_timeout: not_pending, sem esperar o job" do
    stub_const("Signatures::ReturnToPaper::LOCK_TIMEOUT", "200ms")
    first = job
    expect(entered.pop(timeout: 5)).to be(true)
    back = track(Thread.new do
      CityConnection.with(city) do
        Signatures::ReturnToPaper.call(request_id: @rows[:request].id, by: @rows[:user], reason: "sem certificado hoje")
      end
    end)
    expect(back.join(5)).to be_truthy
    expect(first).to be_alive
    expect(back.value.reason).to eq(:not_pending)
    release << true
    expect(first.value).to eq(:signed)
    expect(stored).to eq([ "signed", 1 ])
  end
end
