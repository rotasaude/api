require "rails_helper"

# Módulo 26c, Task 11 (contrato Q7; pré-voo M20): a carga inicial dos pedidos
# que já existiam quando o interruptor `rnds_regulation` liga. A linha existente
# é a marca de feito; o ritmo é do envio (Task 12).
RSpec.describe Regulation::RndsInitialLoadJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 11, 20, 9, 0) }

  before do
    travel_to now
    rnds_regulation_city!(mock: false)
    tick_regulation_events!
  end

  def switch!(enabled)
    Platform::Features.set!(city: Current.city, key: Regulation::RndsGate::KEY, enabled: enabled, maintainer: ledi_maintainer!)
  end

  # Encerra pelo comando de transição; o instante da linha terminal é o do relógio.
  def cancel_at!(request, time)
    travel_to(time)
    result = CareRegulation::Transition.call(request: request.reload, to: "cancelled", by: regulation_regulator!)
    raise "transição recusada: #{result.reason}" if result.failure?

    travel_to(now)
    request
  end

  def rows = RegulationRndsSync.where(initial_load: true)

  it "ligar com 3 pendentes, 1 encerrado há 10 dias e 1 há 40 → 4 linhas initial_load" do
    pending = Array.new(3) { regulation_request! }
    recent = cancel_at!(regulation_request!, now - 10.days)
    old = cancel_at!(regulation_request!, now - 40.days)
    RegulationRndsSync.delete_all

    described_class.perform_now

    expect(rows.pluck(:regulation_request_id)).to contain_exactly(*pending.map(&:id), recent.id)
    expect(rows.pluck(:regulation_request_id)).not_to include(old.id)
    expect(rows.pluck(:status).uniq).to eq([ "queued" ])
    expect(rows.pluck(:desired_status)).to match_array(%w[pending pending pending cancelled])
  end

  it "mede o terminal pela última linha terminal do andamento, não pelo updated_at" do
    old = cancel_at!(regulation_request!, now - 40.days)
    old.update_columns(updated_at: now) # mexida recente que não é andamento
    RegulationRndsSync.delete_all

    described_class.perform_now
    expect(rows.count).to eq(0)
  end

  it "não leva rascunho" do
    regulation_request!(status: "draft")
    described_class.perform_now
    expect(rows.count).to eq(0)
  end

  it "rodar de novo não cria nada nem mexe nas linhas" do
    regulation_request!
    RegulationRndsSync.delete_all
    described_class.perform_now
    sync = rows.first
    first_stamp = sync.reload.updated_at

    travel 5.minutes
    expect { described_class.perform_now }.not_to change { RegulationRndsSync.count }
    expect(sync.reload.updated_at).to eq(first_stamp)
  end

  it "o pedido que nasceu depois entra na rodada seguinte; o que já tinha linha fica como está" do
    first = regulation_request!
    RegulationRndsSync.delete_all
    described_class.perform_now
    second = regulation_request!
    RegulationRndsSync.where(regulation_request_id: second.id).delete_all

    described_class.perform_now
    expect(rows.pluck(:regulation_request_id)).to contain_exactly(first.id, second.id)
  end

  it "desligado → nada" do
    regulation_request!
    RegulationRndsSync.delete_all
    switch!(false)

    described_class.perform_now
    expect(RegulationRndsSync.count).to eq(0)
  end

  it "sem credencial → cria as linhas (nada sai; o envio é da Task 12)" do
    regulation_request!
    RegulationRndsSync.delete_all
    IntegrationCredential.where(kind: "rnds_regulation").delete_all
    expect { described_class.perform_now }.to change { rows.count }.from(0).to(1)
    expect(WebMock).not_to have_requested(:any, /fake-rnds/)
  end

  it "regulado pelo estado só com send_external" do
    regulation_request!(status: "external")
    RegulationRndsSync.delete_all

    described_class.perform_now
    expect(rows.count).to eq(0)

    rnds_settings!(send_external: true)
    described_class.perform_now
    expect(rows.count).to eq(1)
    expect(rows.first).to have_attributes(desired_status: "pending")
  end

  it "usa a mesma recomputação do envio (RndsSync.recompute! com create e initial_load)" do
    request = regulation_request!
    RegulationRndsSync.delete_all
    expect(Regulation::RndsSync).to receive(:recompute!).with(
      satisfy { |r| r.id == request.id }, hash_including(create: true, initial_load: true)
    ).and_call_original

    described_class.perform_now
  end

  context "robustez da rodada" do
    let!(:requests) { Array.new(3) { regulation_request! }.sort_by(&:id) }

    before { RegulationRndsSync.delete_all }

    it "orçamento esgotado depois de N pedidos: a rodada seguinte continua de onde parou" do
      calls = 0
      allow_any_instance_of(described_class).to receive(:expired?) { (calls += 1) > 2 }

      described_class.perform_now
      expect(rows.count).to eq(2)

      allow_any_instance_of(described_class).to receive(:expired?).and_return(false)
      described_class.perform_now
      expect(rows.pluck(:regulation_request_id)).to match_array(requests.map(&:id))
    end

    it "um pedido que levanta não impede os outros; o log só tem id e classe" do
      bad = requests.first
      allow(Regulation::RndsSync).to receive(:recompute!).and_wrap_original do |original, request, **kwargs|
        raise ArgumentError, "CPF 12345678901 vazou" if request.id == bad.id

        original.call(request, **kwargs)
      end
      logged = []
      allow(Rails.logger).to receive(:error) { |msg| logged << msg }

      expect { described_class.perform_now }.not_to raise_error
      expect(rows.pluck(:regulation_request_id)).to match_array(requests.map(&:id) - [ bad.id ])
      expect(logged).to eq([ "[Regulation::RndsInitialLoadJob] regulation_request_id=#{bad.id} ArgumentError" ])
    end

    it "criação concorrente (RecordNotUnique) não aborta a rodada" do
      first = requests.first
      allow(Regulation::RndsSync).to receive(:recompute!).and_wrap_original do |original, request, **kwargs|
        raise ActiveRecord::RecordNotUnique, "duplicate" if request.id == first.id

        original.call(request, **kwargs)
      end

      expect { described_class.perform_now }.not_to raise_error
      expect(rows.count).to eq(2)
    end
  end

  it "70 linhas initial_load → a primeira execução do envio manda 60" do
    pending "depende do Regulation::RndsDeliverJob (Task 12)"
    raise NotImplementedError, "Task 12"
  end
end
