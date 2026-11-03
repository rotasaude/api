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

  it "os dois eventos do trecho estão ligados ao consumidor do BPA" do
    %w[tfd.leg_done tfd.allowances_calculated].each do |name|
      expect(DomainEvents.registry[name].map(&:job)).to eq([ "Billing::TfdProductionJob" ])
    end
  end

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
    expect(rows.first.blocking_reasons).not_to include("establishment_is_aps", "missing_professional_cbo")
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
    expect(described_class.call(TfdAllowance.where(tfd_case: tfd))).to eq(0)
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

  it "billing desligado no momento do trecho: nada, nem quando é religado (sem retroativo)" do
    Platform::Features.set!(city: city, key: "procedure_billing", enabled: false, maintainer: ledi_maintainer!)
    out = tfd_leg_done!(tfd_case!(status: "authorized"), "outbound", Date.current)
    expect(TfdAllowance.where(tfd_leg: out)).to exist
    expect(PerformedProcedure.where(source: "tfd")).to be_empty

    Platform::Features.set!(city: city, key: "procedure_billing", enabled: true, maintainer: ledi_maintainer!)
    perform_enqueued_jobs(only: Billing::TfdProductionJob)
    expect(PerformedProcedure.where(source: "tfd")).to be_empty
  end

  it "sem a unidade de faturamento na configuração: nenhuma linha (e nenhuma exceção)" do
    tfd = tfd_case!(status: "authorized")
    TransportSetting.current.update_columns(tfd_billing_health_unit_id: nil)
    out = tfd_leg_done!(tfd, "outbound", Date.current)
    expect(TfdAllowance.where(tfd_leg: out)).to exist
    expect(PerformedProcedure.where(source: "tfd")).to be_empty
  end
end
