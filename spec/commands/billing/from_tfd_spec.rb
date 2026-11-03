require "rails_helper"

# Produção do TFD no BPA-I (ADR 0048; contrato §6; §14 T11, T26): uma linha
# de performed_procedures (source tfd) por linha de tfd_allowances, com o
# médico do laudo (CBO gravado no processo), a unidade de faturamento do TFD,
# a data do trecho, o CID do laudo e caráter eletivo; tfd_leg_id de rastro.
# Os dois eventos (tfd.leg_done e tfd.allowances_calculated) vão ao mesmo
# Billing::TfdProductionJob; procedure_billing desligado no momento → nada.
RSpec.describe Billing::FromTfd do
  include ActiveJob::TestHelper

  let!(:city) { transport_city!(tfd: true, billing: true) }
  let(:unit) { health_management_unit! }
  let(:companion_codes) { %w[0803010044 0803010052 0803010079 0803010095 0803010109] }

  before { Transport::SaveSettings.call(attrs: { "tfd_billing_health_unit_id" => unit.id }, by: transport_admin!) }

  def job_args(leg, name: "tfd.leg_done")
    { event_id: SecureRandom.uuid, event_name: name, city_slug: Current.city.slug, payload: { "tfd_leg_id" => leg.id } }
  end

  # O evento gravado (DomainEvent) do trecho, para rodar o consumidor com o MESMO event_id.
  def event_args(name, leg)
    event = DomainEvent.where(name: name).find { |e| e.payload["tfd_leg_id"] == leg.id } or raise "sem #{name} do trecho"
    { event_id: event.id, event_name: name, city_slug: Current.city.slug, payload: event.payload }
  end

  # Trecho de passagem registrado e feito SEM rodar o consumidor (fila limpa).
  def ticket_leg!(tfd, direction, on)
    leg = Tfd::AddLeg.call(tfd_case: tfd.reload, by: committee, attrs: { "direction" => direction, "mode" => "bus_ticket", "date" => on.iso8601,
                                                                       "ticket" => { "amount_cents" => 15_000, "carrier" => "Viação" } })
                     .payload.fetch(:leg)
    done = Tfd::CompleteLeg.call(leg: leg, by: committee, at: Time.zone.parse("#{on.iso8601} 18:00"))
    raise "trecho não feito: #{done.reason}" if done.failure?

    clear_enqueued_jobs
    leg.reload
  end

  let(:committee) { committee! }

  it "uma linha BPA-I por ajuda, com o médico do laudo, a unidade de gestão e a data do trecho; sem establishment_is_aps" do
    tfd = tfd_case!(status: "authorized")
    out = tfd_leg_done!(tfd, "outbound", Date.current - 1)
    allowance = TfdAllowance.find_by!(tfd_leg: out)
    rows = PerformedProcedure.where(source: "tfd")
    # 380 km do destino padrão do tfd_case! → 8 unidades de 50 km.
    expect(rows.pluck(:sigtap_code, :quantity, :performed_on, :health_unit_id, :professional_user_id, :cbo_code))
      .to eq([ [ "0803010125", 8, Date.current - 1, unit.id, tfd.requester_user_id, tfd.requester_cbo ] ])
    expect(rows.first).to have_attributes(instrument: "bpa_i", tfd_leg_id: out.id, tfd_allowance_id: allowance.id, patient_id: tfd.patient_id,
                                          cid10: "N185", character: "elective", recorded_by_user_id: nil, exam_provider_id: nil)
    expect(rows.first).to have_attributes(billable: true, blocking_reasons: [])
    expect(Billing::Json.procedure(rows.first)).to include(source: "tfd", source_ref: { type: "tfd_allowance", id: allowance.id })
    expect(rows.first.billing_period).to have_attributes(health_unit_id: unit.id, competence: (Date.current - 1).strftime("%Y%m"))
  end

  it "ida e volta: deslocamento de cada trecho e a alimentação na volta, cada ajuda com a sua linha e a data do seu trecho" do
    tfd = tfd_case!(status: "authorized")
    out = tfd_leg_done!(tfd, "outbound", Date.current - 3)
    back = tfd_leg_done!(tfd, "return", Date.current)
    rows = PerformedProcedure.where(source: "tfd")
    expect(rows.count).to eq(TfdAllowance.where(tfd_case: tfd).count)
    expect(rows.pluck(:tfd_allowance_id)).to match_array(TfdAllowance.where(tfd_case: tfd).ids)
    expect(rows.order(:performed_on, :sigtap_code).pluck(:tfd_leg_id, :sigtap_code, :quantity, :performed_on))
      .to eq([ [ out.id, "0803010125", 8, Date.current - 3 ],
               [ back.id, "0803010010", 3, Date.current ],
               [ back.id, "0803010125", 8, Date.current ] ])
  end

  it "rodar o job de novo (outro evento do mesmo trecho, ou FromTfd direto) não cria linha nova" do
    tfd = tfd_case!(status: "authorized")
    out = tfd_leg_done!(tfd, "outbound", Date.current - 3)
    back = tfd_leg_done!(tfd, "return", Date.current)
    expect(PerformedProcedure.where(source: "tfd").count).to eq(3)

    expect do
      Billing::TfdProductionJob.new.perform(**job_args(out))
      Billing::TfdProductionJob.new.perform(**job_args(back, name: "tfd.allowances_calculated"))
      Billing::TfdProductionJob.new.perform(**job_args(back))
    end.not_to change(PerformedProcedure, :count)
    expect(described_class.call(TfdAllowance.where(tfd_case: tfd))).to eq(created: 0, skipped: [])
    expect(PerformedProcedure.where(source: "tfd").count).to eq(3)
  end

  it "Review Focus 4: acompanhante faltou na frota e o paciente embarcou — só o deslocamento e a alimentação do paciente, nenhuma linha de acompanhante" do
    patient = transport_patient!(birth_date: "1950-01-01")
    tfd = tfd_case!(status: "authorized", patient: patient, report: { "companion_indicated" => true })
    driver = driver_user!
    trip = trip!(date: Date.current, vehicle: vehicle!, driver: driver.transport_driver, status: "confirmed",
                 destination: tfd.transport_destination)
    rider = passenger!(trip, patient: patient, origin: "tfd", tfd_case: tfd, exception_reason: nil, companion_name: "Filha",
                             companion_attendance: "pending")
    committee = committee!
    [ [ "outbound", trip.date ], [ "return", trip.return_at.in_time_zone.to_date ] ].each do |direction, on|
      added = Tfd::AddLeg.call(tfd_case: tfd.reload, by: committee,
                               attrs: { "direction" => direction, "mode" => "fleet", "date" => on.iso8601, "trip_passenger_id" => rider.id })
      raise "trecho recusado: #{added.reason} #{added.details}" if added.failure?
    end

    close_trip!(trip, rider => { attendance: "boarded", companion_attendance: "no_show" }) # Task 8 pelo caminho real

    legs = TfdLeg.where(tfd_case: tfd)
    expect(legs.map(&:done?)).to eq([ true, true ])
    allowances = TfdAllowance.where(tfd_case: tfd)
    expect(allowances.where(kind: "ground_km").pluck(:person)).to eq(%w[patient patient])
    meals = allowances.where(kind: %w[meal_day meal_overnight])
    expect(meals.map(&:person)).to eq([ "patient" ]) # a volta não traz refeição do acompanhante
    expect(meals.sole.tfd_leg.direction).to eq("return")

    rows = PerformedProcedure.where(source: "tfd")
    expect(rows.pluck(:sigtap_code)).to match_array(%w[0803010125 0803010125 0803010028])
    expect(rows.pluck(:sigtap_code) & companion_codes).to be_empty
    expect(rows.pluck(:tfd_allowance_id)).to match_array(allowances.ids)
  end

  it "billing desligado no momento do trecho: nada; religado, o MESMO evento de novo também não cria (sem retroativo)" do
    Platform::Features.set!(city: city, key: "procedure_billing", enabled: false, maintainer: ledi_maintainer!)
    out = tfd_leg_done!(tfd_case!(status: "authorized"), "outbound", Date.current)
    expect(TfdAllowance.where(tfd_leg: out)).to exist
    expect(PerformedProcedure.where(source: "tfd")).to be_empty
    args = event_args("tfd.leg_done", out)
    expect(ProcessedEvent.where(event_id: args[:event_id], consumer: "Billing::TfdProductionJob")).to exist # o consumidor rodou

    Platform::Features.set!(city: city, key: "procedure_billing", enabled: true, maintainer: ledi_maintainer!)
    expect { Billing::TfdProductionJob.new.perform(**args) }.not_to change(PerformedProcedure, :count)
    expect(PerformedProcedure.where(source: "tfd")).to be_empty
  end

  it "I2: sem a unidade de faturamento, o consumidor falha (só ids) e o evento fica pendente; configurada, o mesmo evento grava" do
    tfd = tfd_case!(status: "authorized")
    TransportSetting.current.update_columns(tfd_billing_health_unit_id: nil)
    out = ticket_leg!(tfd, "outbound", Date.current)
    allowance = TfdAllowance.find_by!(tfd_leg: out)
    args = event_args("tfd.leg_done", out)

    expect { Billing::TfdProductionJob.new.perform(**args) }
      .to raise_error(Billing::FromTfd::BillingUnitMissing, "tfd_billing_health_unit_missing tfd_allowance_ids=#{allowance.id}")
    expect(PerformedProcedure.where(source: "tfd")).to be_empty
    expect(DomainEvent.find(args[:event_id]).published_at).to be_nil
    expect(ProcessedEvent.where(event_id: args[:event_id])).not_to exist

    TransportSetting.current.update_columns(tfd_billing_health_unit_id: unit.id)
    Billing::TfdProductionJob.new.perform(**args)
    expect(PerformedProcedure.where(source: "tfd").pluck(:tfd_allowance_id, :health_unit_id)).to eq([ [ allowance.id, unit.id ] ])
    expect(DomainEvent.find(args[:event_id]).published_at).to be_present
  end

  it "I1/FW15: ajuda com quantidade acima de 999 é pulada (só no retorno, sem log) e as outras do trecho seguem, sem exceção" do
    tfd = tfd_case!(status: "authorized")
    ticket_leg!(tfd, "outbound", Date.current - 3)
    back = ticket_leg!(tfd, "return", Date.current)
    # Linha patológica gravada direto (o AddLeg já recusa a volta além de 999 noites).
    huge = TfdAllowance.create!(tfd_case: tfd, tfd_leg: back, person: "companion", kind: "meal_overnight", sigtap_code: "0803010044",
                                quantity: 1000, table_cents: 2475, complement_cents: 0, total_cents: 2_475_000,
                                competence: Date.current.strftime("%Y%m"))
    allow(Rails.logger).to receive(:warn).and_call_original

    expect(described_class.call(TfdAllowance.where(tfd_leg: back))).to eq(created: 2, skipped: [ huge.id ])
    expect(PerformedProcedure.where(tfd_leg_id: back.id).pluck(:sigtap_code)).to contain_exactly("0803010125", "0803010010")
    expect(PerformedProcedure.where(tfd_allowance_id: huge.id)).not_to exist
    expect(Rails.logger).not_to have_received(:warn)
  end

  it "FW9: sem a unidade, a nova tentativa é limitada — reenfileira o mesmo evento até a 12ª execução e então desiste (falha visível)" do
    tfd = tfd_case!(status: "authorized")
    TransportSetting.current.update_columns(tfd_billing_health_unit_id: nil)
    out = ticket_leg!(tfd, "outbound", Date.current)
    args = event_args("tfd.leg_done", out)
    expect(Billing::TfdProductionJob::RETRY_ATTEMPTS).to eq(12)

    calls = 0
    allow(Billing::FromTfd).to receive(:call).and_wrap_original do |original, *rest|
      calls += 1
      original.call(*rest)
    end
    Billing::TfdProductionJob.perform_later(**args)
    raised = nil
    20.times do
      perform_enqueued_jobs(only: Billing::TfdProductionJob)
    rescue Billing::FromTfd::BillingUnitMissing => e
      raised = e
      break
    end
    expect(raised).to be_a(Billing::FromTfd::BillingUnitMissing)
    expect(calls).to eq(12) # 1 + 11 novas tentativas, e para
    expect(enqueued_jobs.count { |job| job["job_class"] == "Billing::TfdProductionJob" }).to eq(0)
    expect(ProcessedEvent.where(event_id: args[:event_id])).not_to exist
    expect(DomainEvent.find(args[:event_id]).published_at).to be_nil
  end

  it "erro do banco no INSERT vira InsertFailed só com o id da ajuda, sem a causa do Postgres (que traz a linha com CID)" do
    tfd = tfd_case!(status: "authorized")
    out = ticket_leg!(tfd, "outbound", Date.current)
    allowance = TfdAllowance.find_by!(tfd_leg: out)
    allow(Billing::Record).to receive(:insert!)
      .and_raise(ActiveRecord::StatementInvalid, "PG::CheckViolation: DETAIL: Failing row contains (N185, #{tfd.patient_id})")

    expect { described_class.call([ allowance ]) }.to raise_error(Billing::FromTfd::InsertFailed) do |error|
      expect(error.message).to eq("tfd_allowance_id=#{allowance.id} ActiveRecord::StatementInvalid")
      expect(error.cause).to be_nil
    end
  end
end
