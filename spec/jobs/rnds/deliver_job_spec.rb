require "rails_helper"
require "webmock/rspec"
require_relative "../../../lib/fake_rnds/app"

# Módulo 29, Task 13 (ADR 0047, Desvios 12 a 16; §15 V7, V8, V23; Review
# Focus 3): a fila de envio à RNDS de ponta a ponta, com o FakeRnds::App em
# processo (WebMock#to_rack). Nenhuma URL real.
RSpec.describe Rnds::DeliverJob do
  include ActiveSupport::Testing::TimeHelpers

  let(:base) { "http://fake-rnds.test:8094" }
  let!(:city) { vaccination_city!(rnds: true).tap { cnes_city! } }
  let(:fake) { FakeRnds::App.new(timeout_delay: 0) }
  let(:room) { vaccine_room!(create_unit("UBS Vacina", cnes: "1234567")) }
  let(:vaccinator) { room_member!(room, role: "vaccinator") }
  let(:lead) { room_member!(room, role: "room_lead", cbo: "223505") }
  let(:child) { vaccine_patient!(birth_date: Date.current - 61) }

  before do
    Rnds::Client.reset_cache!
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FAKE_RNDS_URL").and_return(base)
    stub_request(:any, /\A#{Regexp.escape(base)}/).to_rack(fake)
    cnes_snapshot!(bonds: [ { cnes: "1234567", cbo_code: "322205", cns: vaccinator.professional.cns, cpf: nil, ine: nil },
                            { cnes: "1234567", cbo_code: "223505", cns: lead.professional.cns, cpf: nil, ine: nil } ])
  end

  def run! = described_class.perform_now
  def entries(dose) = RndsOutboxEntry.where(immunization_id: dose.id)
  def entry(dose, kind = "application") = entries(dose).find_by!(kind: kind)
  def posts = fake.log.count { |verb, path, _| verb == "POST" && path.end_with?("/Bundle") }
  def pending_ids(room) = Vaccination::Pending.scope(room, rnds_enabled: true).map(&:immunization_id)

  def cancel!(dose, replacement: nil)
    result = Vaccination::CancelImmunization.call(immunization: dose, reason: "Dose registrada por engano na sala",
                                                  replacement: replacement, by: lead)
    raise "cancel! failed: #{result.reason} #{result.details}" if result.failure?

    result.payload[:replacement]
  end

  def replacement_attrs(lot)
    { "immunobiological_code" => lot.immunobiological_code, "dose_code" => "1", "strategy" => "1", "care_group" => "121",
      "route" => "3", "site" => "18", "maternal_condition" => "1", "applied_at" => Time.current.iso8601, "lot_id" => lot.id }
  end

  it "aceita: guarda o id, anula o payload, publica só ids" do
    dose = record!(room, child, by: vaccinator)
    run!
    expect(entry(dose)).to have_attributes(status: "accepted", payload: nil, rnds_id: fake.accepted.last[:id], attempts: 1, error: nil)
    expect(entry(dose).first_attempt_at).to be_present
    expect(entry(dose).sent_at).to be_present
    expect(fake.log.last[2]["authorization"]).to eq(vaccinator.professional.cns)
    expect(DomainEvent.where(name: "rnds.immunization_accepted").last.payload)
      .to eq("outbox_id" => entry(dose).id, "immunization_id" => dose.id)
  end

  it "cancelamento espera o aceite do original e vai como Bundle substituto com o rnds_id dele" do
    dose = record!(room, child, by: vaccinator)
    fake.failures.push(503)
    run!
    expect(entry(dose)).to have_attributes(status: "pending", attempts: 1)
    expect(entry(dose).first_attempt_at).to be_present # tentada: o cancelamento nasce (V23)
    cancel!(dose)
    expect(entries(dose).pluck(:kind, :status)).to contain_exactly(%w[application pending], %w[cancellation pending])
    travel 2.minutes do
      run!
      expect(entries(dose).pluck(:kind, :status)).to contain_exactly(%w[application accepted], %w[cancellation pending])
      run!
    end
    expect(entries(dose).pluck(:status).uniq).to eq([ "accepted" ])
    composition = fake.accepted.last[:bundle]["entry"].first["resource"]
    expect(composition["relatesTo"]).to eq([ { "code" => "replaces", "targetIdentifier" => { "value" => entry(dose).rnds_id } } ])
    expect(fake.accepted.last[:bundle]["entry"].last["resource"]["status"]).to eq("entered-in-error")
  end

  it "Review Focus 3: recusada (422) e cancelada pela técnica: nenhum cancelamento nasce; a substituta vai; a pendência some" do
    dose = record!(room, child, by: vaccinator, lot: vaccine_lot!(room, code: "42", lot_number: "RECUSA"))
    run!
    expect(entry(dose)).to have_attributes(status: "rejected", error: "Lote inválido para o CPF ***", attempts: 1)
    expect(DomainEvent.where(name: "rnds.immunization_rejected").last.payload)
      .to eq("outbox_id" => entry(dose).id, "immunization_id" => dose.id)
    expect(pending_ids(room)).to eq([ dose.id ])
    replacement = cancel!(dose, replacement: replacement_attrs(vaccine_lot!(room, code: "42")))
    run!
    expect(entries(dose).pluck(:kind)).to eq([ "application" ])
    expect(entries(replacement).sole.status).to eq("accepted")
    expect(posts).to eq(2)
    expect(pending_ids(room)).not_to include(dose.id)
    travel 25.hours do
      expect(Rnds::Alert.counts(now: Time.current)).to include(rejected: 0, late: 0)
    end
  end

  it "bloqueada fica blocked com o motivo, sem payload nem tentativa, e revalida depois de 1 h" do
    patient = vaccine_patient!(birth_date: Date.current - 70, cpf: false, cns: false)
    dose = record!(room, patient, by: vaccinator)
    freeze_time(1.second.from_now) do
      run!
      expect(entry(dose)).to have_attributes(status: "blocked", block_reason: "patient_without_cns_or_cpf", payload: nil, attempts: 0,
                                             first_attempt_at: nil)
      expect(entry(dose).next_attempt_at).to eq(1.hour.from_now)
    end
    run!
    expect(fake.log).to be_empty
    patient.update!(cns: valid_cns(registry_seq!))
    travel 61.minutes do
      run!
    end
    expect(entry(dose)).to have_attributes(status: "accepted", block_reason: nil)
  end

  it "credencial recusada: lote devolvido sem contar tentativa e credencial marcada" do
    fake.failures.push(401)
    record!(room, child, by: vaccinator)
    record!(room, vaccine_patient!(birth_date: Date.current - 61), by: vaccinator)
    run!
    expect(RndsOutboxEntry.pluck(:status, :attempts, :first_attempt_at)).to eq([ [ "pending", 0, nil ] ] * 2)
    expect(IntegrationCredential.find_by(kind: "rnds").last_check_status).to eq("unauthorized")
    requests = fake.log.size
    run! # credencial recusada: `rnds_immunization` inutilizável, nada sai
    expect(fake.log.size).to eq(requests)
  end

  it "envio desligado: nada sai; a dose fica pending e aparece como not_sent" do
    Platform::Features.set!(city: city, key: "rnds_immunization", enabled: false, maintainer: ledi_maintainer!)
    dose = record!(room, child, by: vaccinator)
    run!
    expect(fake.log).to be_empty
    expect(entry(dose).status).to eq("pending")
    expect(Vaccination::Json.rnds(entry(dose), false)[:status]).to eq("not_sent")
  end

  it "dose cancelada nunca tentada: o job nunca reivindica a application (V23)" do
    dose = record!(room, child, by: vaccinator)
    cancel!(dose)
    run!
    expect(fake.log).to be_empty
    expect(entries(dose).pluck(:kind, :status)).to eq([ %w[application pending] ])
  end

  it "cancelamento órfão: o original em sending vira rejected; o cancelamento não é enviado e sai das pendências e do atraso" do
    dose = record!(room, child, by: vaccinator)
    claimed = RndsOutboxEntry.claim!(limit: 20)
    expect(entry(dose).status).to eq("sending")
    cancel!(dose) # a application estava em voo: conta como tentada e o cancelamento nasce
    expect(entry(dose, "cancellation").status).to eq("pending")
    fake.failures.push(nil, 422) # token normal; o Bundle recusado
    Rnds::Delivery.new(city).run(claimed)
    expect(entry(dose).status).to eq("rejected")
    travel 2.minutes do
      run!
      expect(posts).to eq(1)
    end
    expect(entry(dose, "cancellation")).to have_attributes(status: "pending", attempts: 0, first_attempt_at: nil)
    expect(pending_ids(room)).to be_empty
    travel 25.hours do
      expect(Rnds::Alert.counts(now: Time.current)).to eq(pending: 0, blocked: 0, rejected: 0, failed: 0, late: 0)
    end
  end

  it "original aceito sem rnds_id (201 sem Location): o cancelamento vira failed com erro claro, sem quebrar o lote" do
    dose = record!(room, child, by: vaccinator)
    run!
    entry(dose).update_columns(rnds_id: nil)
    cancel!(dose)
    other = record!(room, vaccine_patient!(birth_date: Date.current - 61), by: vaccinator)
    run!
    expect(entry(dose, "cancellation")).to have_attributes(status: "failed", error: "original_without_rnds_id", payload: nil)
    expect(entry(other).status).to eq("accepted")
    expect(posts).to eq(2)
  end

  it "5xx: pending com espera crescente; failed só depois de 15 dias da primeira tentativa (V7)" do
    dose = record!(room, child, by: vaccinator)
    fake.failures.push(503)
    freeze_time(1.second.from_now) do
      run!
      expect(entry(dose)).to have_attributes(status: "pending", attempts: 1, error: "rnds_unavailable")
      expect(entry(dose).next_attempt_at).to eq(1.minute.from_now)
      expect(entry(dose).payload).to be_present
    end
    entry(dose).update_columns(first_attempt_at: 14.days.ago, next_attempt_at: 1.minute.ago)
    fake.failures.push(503)
    run!
    expect(entry(dose)).to have_attributes(status: "pending", attempts: 2)
    entry(dose).update_columns(first_attempt_at: 15.days.ago - 1.minute, next_attempt_at: 1.minute.ago)
    fake.failures.push(503)
    run!
    expect(entry(dose)).to have_attributes(status: "failed", attempts: 3)
  end

  it "timeout conta como tentada" do
    dose = record!(room, child, by: vaccinator, lot: vaccine_lot!(room, code: "42", lot_number: "TIMEOUT"))
    run!
    expect(entry(dose)).to have_attributes(status: "pending", attempts: 1)
    expect(entry(dose)).to be_attempted
  end

  it "banco da cidade inalcançável na validação: a entrada volta com espera e o resto do lote segue" do
    first = record!(room, child, by: vaccinator)
    second = record!(room, vaccine_patient!(birth_date: Date.current - 61), by: vaccinator)
    calls = 0
    allow(Rnds::Validation).to receive(:call).and_wrap_original do |original, **kwargs|
      calls += 1
      raise ActiveRecord::ConnectionNotEstablished, "down" if calls == 1

      original.call(**kwargs)
    end
    run!
    statuses = [ entry(first), entry(second) ].map { |e| [ e.status, e.error ] }
    expect(statuses).to contain_exactly([ "pending", "city_unreachable" ], [ "accepted", nil ])
    expect(RndsOutboxEntry.where(status: "pending").sole.first_attempt_at).to be_nil
  end

  it "erro inesperado numa entrada: ela volta a pending com código e o resto do lote segue" do
    first = record!(room, child, by: vaccinator)
    second = record!(room, vaccine_patient!(birth_date: Date.current - 61), by: vaccinator)
    calls = 0
    allow(Rnds::Bundle).to receive(:build).and_wrap_original do |original, **kwargs|
      calls += 1
      raise "segredo do paciente" if calls == 1

      original.call(**kwargs)
    end
    run!
    statuses = [ entry(first), entry(second) ].map { |e| [ e.status, e.error ] }
    expect(statuses).to contain_exactly([ "pending", "internal_error" ], [ "accepted", nil ])
    expect(RndsOutboxEntry.where.not(error: nil).pluck(:error).join).not_to include("segredo")
  end

  it "o ensure devolve a pending o que sobrou em sending; sending esquecido há mais de 10 min volta à fila" do
    dose = record!(room, child, by: vaccinator)
    allow_any_instance_of(Rnds::Delivery).to receive(:run).and_raise(RuntimeError, "falha")
    expect { run! }.to raise_error(EachCityJob::AggregatedFailure)
    expect(entry(dose).status).to eq("pending")
    allow_any_instance_of(Rnds::Delivery).to receive(:run).and_call_original
    entry(dose).update_columns(status: "sending", updated_at: 11.minutes.ago)
    run!
    expect(entry(dose).status).to eq("accepted")
  end

  it "entrada roubada (release_stale! + claim de outra execução) não é enviada nem devolvida pela execução antiga" do
    first = record!(room, child, by: vaccinator)
    second = record!(room, vaccine_patient!(birth_date: Date.current - 61), by: vaccinator)
    stale = RndsOutboxEntry.claim!(limit: 20)
    RndsOutboxEntry.where(id: stale.map(&:id)).update_all(updated_at: 11.minutes.ago)
    fresh = travel(1.second) do
      RndsOutboxEntry.release_stale!(before: 10.minutes.ago)
      RndsOutboxEntry.claim!(limit: 20)
    end
    expect(fresh.map(&:id)).to match_array(stale.map(&:id))

    expect(Rnds::Delivery.new(city).run(stale)).to eq(:done) # a execução antiga, atrasada
    expect(posts).to eq(0)
    RndsOutboxEntry.release!(stale.map(&:id), token: stale.first.last_attempted_at) # o ensure dela
    expect([ entry(first), entry(second) ].map(&:status)).to eq(%w[sending sending])

    Rnds::Delivery.new(city).run(fresh)
    expect([ entry(first), entry(second) ].map(&:status)).to eq(%w[accepted accepted])
    expect(posts).to eq(2) # uma vez por dose
  end

  it "orçamento do lote esgotado: o resto volta a pending sem tentativa e sai na rodada seguinte" do
    first = record!(room, child, by: vaccinator)
    second = record!(room, vaccine_patient!(birth_date: Date.current - 61), by: vaccinator)
    ticks = [ 0.0, 0.0, Rnds::Delivery::BUDGET.to_f + 1 ]
    clock = -> { ticks.size > 1 ? ticks.shift : ticks.first }
    entries = RndsOutboxEntry.claim!(limit: 20)
    expect(Rnds::Delivery.new(city, clock: clock).run(entries)).to eq(:done)
    statuses = [ entry(first), entry(second) ].map { |e| [ e.status, e.attempts, e.first_attempt_at.nil? ] }
    expect(statuses).to contain_exactly([ "accepted", 1, false ], [ "pending", 0, true ])
    expect(posts).to eq(1)
    run!
    expect([ entry(first), entry(second) ].map(&:status)).to eq(%w[accepted accepted])
    expect(Rnds::Delivery::BUDGET).to be < described_class::STALE_SENDING / 2
  end

  it "é recorrente a cada minuto e um lote por cidade de cada vez" do
    recurring = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    expect(recurring.values.filter_map { |tasks| tasks.is_a?(Hash) && tasks["rnds_deliver"] }.first)
      .to include("class" => "Rnds::DeliverJob", "schedule" => "every minute")
    expect(described_class.concurrency_key).to be_present
    expect(described_class.concurrency_limit).to eq(1)
    expect(described_class.concurrency_duration).to eq(10.minutes)
  end
end
