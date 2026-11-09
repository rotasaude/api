require "rails_helper"
require Rails.root.join("db/city_migrate/20261105900006_add_urgency_billing_source.rb").to_s

# BPA da urgência pelo 22 (ADR 0050; contrato §9 e §14 Q12, Q25; Review Focus
# 5): no fechamento do encontro (urgency.encounter_closed) e na identificação
# do provisório (urgency.patient_identified), Billing::UrgencyProductionJob
# grava, com source urgency e o encontro: a classificação de risco
# (classification_code) com quem fez a 1ª classificação e o atendimento médico
# (care_code) com o autor da consulta de urgência finalizada. Provisório não
# identificado: nada, e a competência mostra a pendência sem linha (fix
# patient). Evasão antes da classificação e registro por engano: nada.
# Idempotente pelos códigos do encontro (e o índice único).
RSpec.describe Billing::FromUrgency do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { urgency_city!(billing: true) }
  let(:upa) { upa!.tap { |u| u.update!(cnes: billing_cnes) } }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  let(:codes) { Urgency::Config.sigtap }

  before { ciap2_release! }

  def closed_with(encounter, kind)
    called!(encounter, by: doctor)
    finalized_urgency!(encounter, doctor: doctor)
    Urgency::RecordOutcome.call(encounter: encounter.reload, attrs: { "kind" => kind }, by: doctor)
  end

  def run_jobs = perform_enqueued_jobs(only: Billing::UrgencyProductionJob)

  def job_args(name, encounter)
    { event_id: SecureRandom.uuid, event_name: name, city_slug: Current.city.slug, payload: { "encounter_id" => encounter.id } }
  end

  def lines(encounter) = PerformedProcedure.where(urgency_encounter_id: encounter.id)

  it "identificado: duas linhas, uma por profissional; reprocessar não duplica" do
    e = arrived!(upa, patient: urgency_patient!(1)).tap { |x| classified!(x, color: "yellow", by: nurse, justification: "Conferido na classificação") }
    closed_with(e, "discharged")
    run_jobs
    rows = lines(e).order(:sigtap_code)
    expect(rows.map { |r| [ r.sigtap_code, r.professional_user_id, r.source, r.character ] })
      .to eq([ [ "0301060096", doctor.id, "urgency", "urgent" ], [ "0301060118", nurse.id, "urgency", "urgent" ] ])
    classification = e.classifications.first
    consultation = Consultation.find_by!(attendance_id: e.attendance_id)
    expect(rows.first).to have_attributes(cbo_code: consultation.cbo_code, consultation_id: consultation.id, attendance_id: e.attendance_id,
                                          patient_id: e.patient.id, health_unit_id: upa.id, quantity: 1, recorded_by_user_id: nil,
                                          performed_on: consultation.finalized_at.in_time_zone.to_date, cid10: nil)
    expect(rows.last).to have_attributes(cbo_code: classification.cbo_code, consultation_id: nil, attendance_id: e.attendance_id,
                                         performed_on: classification.created_at.in_time_zone.to_date, cid10: nil)
    expect(described_class.call(e.reload)).to eq(created: 0, pending: nil)
    expect { described_class.call(e.reload) }.not_to change(PerformedProcedure, :count)
    expect(Billing::Json.procedure(rows.first)).to include(source: "urgency", source_ref: { type: "urgency_encounter", id: e.id })
  end

  it "óbito de provisório: nenhuma linha, pendência fix patient; a identificação gera no real, sem duplicar no replay (RF5)" do
    e = arrived!(upa, unidentified: "Homem, 60 anos").tap { |x| classified!(x, color: "red", by: nurse, vital_signs: { spo2: 80 }) }
    closed_with(e, "death")
    run_jobs
    expect(lines(e)).to be_empty
    expect(described_class.call(e.reload)).to eq(created: 0, pending: :patient)
    period, = Billing::Periods.assign!(Billing::Establishment.for_unit(upa), Time.zone.today.strftime("%Y%m"))
    item = Billing::Pending.call(period).find { |r| r[:urgency_encounter_id] == e.id }
    provisional = e.patient
    expect(item).to eq(
      procedure_id: nil, urgency_encounter_id: e.id, reasons: [ "patient_unidentified" ], fix: "patient", late: false,
      performed_on: e.classifications.first.created_at.in_time_zone.to_date.iso8601, sigtap_code: codes["classification_code"],
      label: "ACOLHIMENTO COM CLASSIFICACAO DE RISCO",
      patient: { id: provisional.id, display_name: "Paciente não identificado", has_cpf: false, cns_masked: nil, address_from_household: false },
      professional: { user_id: nurse.id, name: Screenings::Json.staff_name(nurse) }
    )
    real = urgency_patient!(2)
    travel 1.day do
      Urgency::Identify.call(encounter: e.reload, patient_id: real.id, by: reception!)
      run_jobs
    end
    expect(lines(e).pluck(:patient_id).uniq).to eq([ real.id ])
    expect(lines(e).pluck(:sigtap_code)).to match_array([ codes["classification_code"], codes["care_code"] ])
    expect(Billing::Pending.call(period).none? { |r| r[:urgency_encounter_id] == e.id }).to be(true)

    identified = DomainEvent.where(name: "urgency.patient_identified").find { |ev| ev.payload["encounter_id"] == e.id }
    same = { event_id: identified.id, event_name: identified.name, city_slug: Current.city.slug, payload: identified.payload }
    expect { Billing::UrgencyProductionJob.new.perform(**same) }.not_to change(PerformedProcedure, :count)
    expect { Billing::UrgencyProductionJob.new.perform(**job_args("urgency.patient_identified", e)) }.not_to change(PerformedProcedure, :count)
    expect { Billing::UrgencyProductionJob.new.perform(**job_args("urgency.encounter_closed", e)) }.not_to change(PerformedProcedure, :count)
  end

  it "evasão antes da classificação não gera linha nem pendência" do
    e = arrived!(upa, unidentified: "Mulher, 25 anos")
    Urgency::RecordOutcome.call(encounter: e, attrs: { "kind" => "left_without_care" }, by: reception!)
    run_jobs
    expect(lines(e)).to be_empty
    period, = Billing::Periods.assign!(Billing::Establishment.for_unit(upa), Time.zone.today.strftime("%Y%m"))
    expect(Billing::Pending.call(period).none? { |r| r[:urgency_encounter_id] == e.id }).to be(true)
  end

  it "evasão depois da classificação: só a linha da classificação (sem consulta finalizada, sem atendimento)" do
    e = arrived!(upa).tap { |x| classified!(x, color: "green", by: nurse) }
    Urgency::RecordOutcome.call(encounter: e, attrs: { "kind" => "left_without_care" }, by: reception!)
    run_jobs
    expect(lines(e).pluck(:sigtap_code, :professional_user_id)).to eq([ [ codes["classification_code"], nurse.id ] ])
  end

  it "registro por engano (Q25) não gera linha nem pendência, nem do provisório" do
    e = arrived!(upa, unidentified: "Homem, 30 anos").tap { |x| classified!(x, color: "green", by: nurse) }
    result = Urgency::RecordOutcome.call(encounter: e, attrs: { "kind" => "registered_in_error", "reason" => "Chegada duplicada pela recepção" },
                                         by: reception!)
    expect(result).to be_ok
    run_jobs
    expect(lines(e)).to be_empty
    expect(described_class.call(e.reload)).to eq(created: 0, pending: nil)
    period, = Billing::Periods.assign!(Billing::Establishment.for_unit(upa), Time.zone.today.strftime("%Y%m"))
    expect(Billing::Pending.call(period).none? { |r| r[:urgency_encounter_id] == e.id }).to be(true)
  end

  it "encontro aberto: nada" do
    e = arrived!(upa).tap { |x| classified!(x, color: "green", by: nurse) }
    expect(described_class.call(e)).to eq(created: 0, pending: nil)
    expect(lines(e)).to be_empty
  end

  it "o atendimento leva o 1º CID-10 avaliado da consulta; a classificação vai sem CID" do
    e = arrived!(upa).tap { |x| classified!(x, color: "yellow", by: nurse) }
    consultation = urgency_consultation!(e, doctor: doctor)
    problems = [ { "terminology" => "ciap2", "code" => "K86", "action" => "add", "onset_on" => "2025-08-01", "onset_precision" => "month" },
                 { "terminology" => "cid10", "code" => "I10", "action" => "add", "onset_on" => "2025-08-01", "onset_precision" => "month" } ]
    saved = Consultations::SaveDraft.call(consultation: consultation, params: draft_body(evaluated_problems: problems).except("care_type"), by: doctor)
    expect(saved).to be_ok
    expect(Consultations::Finalize.call(consultation: consultation.reload, outcome_params: {}, by: doctor)).to be_ok
    Urgency::RecordOutcome.call(encounter: e.reload, attrs: { "kind" => "discharged" }, by: doctor)
    run_jobs
    expect(lines(e).order(:sigtap_code).pluck(:sigtap_code, :cid10)).to eq([ [ codes["care_code"], "I10" ], [ codes["classification_code"], nil ] ])
  end

  it "procedure_billing desligado no evento: o job não grava" do
    e = arrived!(upa, patient: urgency_patient!(3)).tap { |x| classified!(x, color: "yellow", by: nurse) }
    closed_with(e, "discharged")
    Platform::Features.set!(city: Current.city, key: Billing::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    run_jobs
    expect(lines(e)).to be_empty
  end

  it "erro do banco no INSERT vira InsertFailed só com o id do encontro, sem a causa do Postgres" do
    e = arrived!(upa, patient: urgency_patient!(4)).tap { |x| classified!(x, color: "yellow", by: nurse) }
    closed_with(e, "discharged")
    allow(Billing::Record).to receive(:insert!).and_raise(ActiveRecord::StatementInvalid, "DETAIL: Failing row contains (I10, Fulano)")
    expect { described_class.call(e.reload) }.to raise_error(described_class::InsertFailed) { |error|
      expect(error.message).to eq("urgency_encounter_id=#{e.id} ActiveRecord::StatementInvalid")
      expect(error.cause).to be_nil
    }
  end

  describe "banco (900006)" do
    it "a migração espelha as fontes do modelo" do
      expect(AddUrgencyBillingSource::SOURCES).to eq(PerformedProcedure::SOURCES)
      expect(PerformedProcedure::SOURCES).to include("urgency")
    end

    it "recusa a fonte urgency sem encontro e encontro em outra fonte; uma linha por código do encontro" do
      e = arrived!(upa, patient: urgency_patient!(5))
      patient = e.patient
      expect { raw_procedure!(unit: upa, patient: patient, professional: doctor, source: "urgency") }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_performed_procedures_source_ref/)
      expect { raw_procedure!(unit: upa, patient: patient, professional: doctor, source: "manual", urgency_encounter_id: e.id) }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_performed_procedures_source_ref/)
      raw_procedure!(unit: upa, patient: patient, professional: doctor, source: "urgency", urgency_encounter_id: e.id, sigtap_code: "0301060096")
      expect { raw_procedure!(unit: upa, patient: patient, professional: doctor, source: "urgency", urgency_encounter_id: e.id, sigtap_code: "0301060096") }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_performed_procedures_urgency/)
    end
  end
end
