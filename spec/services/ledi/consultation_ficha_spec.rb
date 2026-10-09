require "rails_helper"

# ADR 0031 (spec §6, §8): a ficha nasce na finalização (exportação
# utilizável); falta de identificação → "não gerada"; duas fichas no mesmo
# atendimento (escuta e consulta); adendo regera antes do aceite e vira
# correction_pending depois — nunca enviada.
RSpec.describe Ledi::ConsultationFicha do
  include ActiveSupport::Testing::TimeHelpers

  let(:city) { ledi_ready!(clinical_city!, pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "4106902") }
  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }

  before do
    Current.city = city
    ciap2_release!; cid10_release!; sigtap_release!
    allow(Ledi::DeliverJob).to receive(:perform_later)
  end
  after { Current.reset }

  def ficha_of(entry)
    Ledi::Version.deserialize(Ledi::FichaTypes.klass(entry.ficha_type), Ledi::Transport.read(entry.bytes).dadoSerializado)
  end

  def finalized!(n = 1, **over)
    exportable_unit!(unit, doctor)
    finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(n), **over)
  end

  def addendum!(consultation, changes) =
    Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "correção estruturada", text: "ajuste", changes: changes)

  it "gera o Atendimento Individual da consulta uma vez; transporte tipo 4; problemas, condutas e exames" do
    consultation = finalized!
    expect(described_class.generate(consultation)).to eq(:enqueued)
    entry = LediOutboxEntry.sole
    expect(entry).to have_attributes(source_type: "Consultation", source_id: consultation.id, ficha_type: "atendimento_individual")
    expect(Ledi::Transport.read(entry.bytes).tipoDadoSerializado).to eq(4)
    child = ficha_of(entry).atendimentosIndividuais.sole
    problem = PatientProblem.sole
    expect([ child.tipoAtendimento, child.condutas, child.exame.map(&:codigoExame) ]).to eq([ 5, [ 1 ], [ "0202010503" ] ])
    item = child.problemasCondicoes.sole
    expect([ item.uuidProblema, item.uuidEvolucaoProblema, item.coSequencialEvolucao, item.ciap, item.situacao ])
      .to eq([ problem.id, ConsultationProblem.sole.id, 1, "T90", 0 ])
    expect(child.medicoes.pressaoArterialSistolica).to eq(130)
    expect(described_class.generate(consultation)).to eq(:exists)
  end

  it "duas fichas no mesmo atendimento: a da escuta (enfermeira) e a da consulta (médica)" do
    nurse = screener!(unit)
    exportable_unit!(unit, nurse, doctor)
    citizen = verified_citizen!(1)
    attendance = walk_in_attendance!(unit, citizen: citizen)
    screening = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    Screenings::Complete.call(screening: screening, revision_params: revision_params, destination: "same_day", destination_params: {}, by: nurse)
    Attendances::Call.call(attendance: attendance, health_unit_id: unit.id, by: doctor)
    consultation = Consultations::Start.call(attendance: attendance.reload, by: doctor).payload[:consultation]
    Consultations::SaveDraft.call(consultation: consultation, params: draft_body(vitals: {}), by: doctor)
    Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: doctor)
    Ledi::ScreeningFicha.generate(screening.reload)
    described_class.generate(consultation.reload)
    expect(LediOutboxEntry.pluck(:source_type).sort).to eq(%w[Consultation Screening])
    # Sem sinais na consulta, as medições vêm da escuta do mesmo atendimento.
    entry = LediOutboxEntry.find_by!(source_type: "Consultation")
    expect(ficha_of(entry).atendimentosIndividuais.sole.medicoes.pressaoArterialSistolica).to eq(130)
  end

  it "sem identificação: 'não gerada' com os motivos; corrigido, gera e resolve" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    consultation.patient.update_columns(sex: nil)
    expect(described_class.generate(consultation)).to eq(:failed)
    failure = LediGenerationFailure.sole
    expect(failure.reason_codes).to eq(%w[unit_without_cnes professional_without_team citizen_without_sex])
    expect(DomainEvent.where(name: "ledi.generation_failed").sole.payload)
      .to eq("failure_id" => failure.id, "source_type" => "Consultation", "source_id" => consultation.id)
    exportable_unit!(unit, doctor)
    consultation.patient.update_columns(sex: "female")
    expect(described_class.retry!(failure, by: ledi_admin!).resolved_at).to be_present
    expect(LediOutboxEntry.where(source_id: consultation.id).count).to eq(1)
  end

  it "exportação desligada ou record_mode off: nada nasce" do
    consultation = finalized!
    ledi_off!(city)
    expect(described_class.generate(consultation)).to eq(:unusable)
    expect([ LediOutboxEntry.count, LediGenerationFailure.count ]).to eq([ 0, 0 ])
  end

  it "adendo antes do aceite: pendente regravada com o mesmo uuid; recusada regerada com replaces" do
    consultation = finalized!
    described_class.generate(consultation)
    entry = LediOutboxEntry.sole
    addendum!(consultation, "conducts" => [ 1, 9 ])
    expect(described_class.refresh!(consultation.reload)).to eq(:rewritten)
    expect(entry.reload.uuid).to eq(entry.uuid)
    expect(ficha_of(entry).atendimentosIndividuais.sole.condutas).to eq([ 1, 9 ])

    entry.reject!([ { "field" => "condutas", "code" => "invalid" } ])
    addendum!(consultation, "conducts" => [ 9 ])
    expect(described_class.refresh!(consultation.reload)).to eq(:regenerated)
    fresh = LediOutboxEntry.find_by!(replaces_outbox_id: entry.id)
    expect([ fresh.status, ficha_of(fresh).atendimentosIndividuais.sole.condutas ]).to eq([ "pending", [ 9 ] ])
  end

  it "adendo depois do aceite: uma correction_pending por aceita, regravada e nunca enviada (api#41)" do
    consultation = finalized!
    described_class.generate(consultation)
    accepted = LediOutboxEntry.sole.tap(&:accept!)
    addendum!(consultation, "conducts" => [ 1, 9 ])
    expect(described_class.refresh!(consultation.reload)).to eq(:correction_pending)
    addendum!(consultation, "conducts" => [ 9 ])
    expect(described_class.refresh!(consultation.reload)).to eq(:correction_pending)
    correction = LediOutboxEntry.find_by!(replaces_outbox_id: accepted.id)
    expect([ correction.status, LediOutboxEntry.count ]).to eq([ "correction_pending", 2 ])
    expect(ficha_of(correction).atendimentosIndividuais.sole.condutas).to eq([ 9 ])
    expect(LediOutboxEntry.claim!(limit: 10)).to be_empty
  end

  # Achado da revisão da Task 15: Ledi::Enqueue#find_existing pegava a linha
  # mais recente da fonte sem olhar o status — a correction_pending.
  it "com correção pendente: o adendo seguinte regrava a mesma; a correção nunca passa pela original" do
    consultation = finalized!
    described_class.generate(consultation)
    accepted = LediOutboxEntry.sole.tap(&:accept!)
    addendum!(consultation, "conducts" => [ 1, 9 ])
    described_class.refresh!(consultation.reload)
    correction = LediOutboxEntry.find_by!(replaces_outbox_id: accepted.id)
    expect(described_class.generate(consultation)).to eq(:exists)
    ficha, = described_class.build(consultation)
    expect(Ledi::Enqueue.call(ficha, city: city)).to eq(accepted)
    addendum!(consultation, "conducts" => [ 9 ])
    expect(described_class.refresh!(consultation.reload)).to eq(:correction_pending)
    expect(LediOutboxEntry.where(replaces_outbox_id: correction.id)).to be_empty
    expect([ correction.reload.uuid, LediOutboxEntry.count, accepted.reload.status ])
      .to eq([ correction.uuid, 2, "accepted" ])
    expect(ficha_of(correction).atendimentosIndividuais.sole.condutas).to eq([ 9 ])
  end

  # Fix round 1: falha nascida no refresh! (a ficha já existe) — "gerar de
  # novo" leva o adendo à ficha em vez de só resolver.
  it "falha do adendo depois do aceite: gerar de novo regrava a correction_pending e resolve" do
    consultation = finalized!
    described_class.generate(consultation)
    accepted = LediOutboxEntry.sole.tap(&:accept!)
    unit.update_columns(cnes: nil)
    addendum!(consultation, "conducts" => [ 1, 9 ])
    expect(described_class.refresh!(consultation.reload)).to eq(:failed)
    failure = LediGenerationFailure.sole
    expect([ failure.reason_codes, LediOutboxEntry.count ]).to eq([ %w[unit_without_cnes], 1 ])
    unit.update_columns(cnes: "1234567")
    expect(described_class.retry!(failure, by: ledi_admin!).resolved_at).to be_present
    correction = LediOutboxEntry.find_by!(replaces_outbox_id: accepted.id)
    expect(correction.status).to eq("correction_pending")
    expect(ficha_of(correction).atendimentosIndividuais.sole.condutas).to eq([ 1, 9 ])
  end

  it "falha do adendo com a ficha pendente: gerar de novo regrava o mesmo uuid" do
    consultation = finalized!
    described_class.generate(consultation)
    entry = LediOutboxEntry.sole
    unit.update_columns(cnes: nil)
    addendum!(consultation, "conducts" => [ 1, 9 ])
    described_class.refresh!(consultation.reload)
    unit.update_columns(cnes: "1234567")
    expect(described_class.retry!(LediGenerationFailure.sole, by: ledi_admin!).resolved_at).to be_present
    expect([ LediOutboxEntry.sole.uuid, ficha_of(entry.reload).atendimentosIndividuais.sole.condutas ])
      .to eq([ entry.uuid, [ 1, 9 ] ])
  end

  # Revisão final: a mesma ordem de travas de refresh!/regenerate (outbox →
  # falha); a ordem inversa arrisca deadlock com o job do adendo.
  it "gerar de novo trava a ficha da consulta ANTES da falha" do
    consultation = finalized!
    described_class.generate(consultation)
    unit.update_columns(cnes: nil)
    addendum!(consultation, "conducts" => [ 1, 9 ])
    described_class.refresh!(consultation.reload)
    unit.update_columns(cnes: "1234567")
    locks = []
    callback = lambda do |*, payload|
      sql = payload[:sql]
      locks << sql[/FROM "(ledi_outbox|ledi_generation_failures)"/, 1] if sql.include?("FOR UPDATE")
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.retry!(LediGenerationFailure.sole, by: ledi_admin!)
    end
    expect(locks.compact.first(2)).to eq(%w[ledi_outbox ledi_generation_failures])
  end

  it "gerar de novo com a ficha em envio: a falha fica aberta e o job tenta de novo" do
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    consultation = finalized!
    described_class.generate(consultation)
    unit.update_columns(cnes: nil)
    addendum!(consultation, "conducts" => [ 1, 9 ])
    described_class.refresh!(consultation.reload)
    failure = LediGenerationFailure.sole
    LediOutboxEntry.update_all(status: "sending")
    unit.update_columns(cnes: "1234567")
    expect(described_class.retry!(failure, by: ledi_admin!).resolved_at).to be_nil
    job = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == Ledi::ConsultationFichaJob }.last
    expect(ActiveJob::Arguments.deserialize(job[:args]).first)
      .to eq(city_slug: city.slug, consultation_id: consultation.id, reason: "addendum")
    expect(DomainEvent.where(name: "ledi.generation_retried").count).to eq(1)
  end

  it "ficha em envio com motivos presentes: InFlight, nunca 'não gerada'" do
    consultation = finalized!
    described_class.generate(consultation)
    LediOutboxEntry.update_all(status: "sending")
    unit.update_columns(cnes: nil)
    addendum!(consultation, "conducts" => [ 1, 9 ])
    expect { described_class.refresh!(consultation.reload) }.to raise_error(described_class::InFlight)
    expect(LediGenerationFailure.count).to eq(0)
  end

  # Decisão do usuário 2026-10-08: consulta de não médico omite CID-10 na ficha.
  it "enfermeira avalia CID-10 da lista e um CIAP-2: a ficha só leva o CIAP-2; a do médico leva o CID-10" do
    nurse = doctor!(unit, cbo: "223505")
    exportable_unit!(unit, doctor, nurse)
    citizen = verified_citizen!(1)
    medical = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen,
                                      evaluated_problems: [ { "terminology" => "cid10", "code" => "E119", "action" => "add" } ])
    nursing = started_consultation!(unit: unit, doctor: nurse, citizen: citizen.reload)
    cid10 = PatientProblem.find_by!(code: "E119")
    problems = [ { "problem_id" => cid10.id, "action" => "evaluate" },
                 { "terminology" => "ciap2", "code" => "T90", "action" => "add" } ]
    Consultations::SaveDraft.call(consultation: nursing, params: draft_body(evaluated_problems: problems), by: nurse)
    result = Consultations::Finalize.call(consultation: nursing.reload, outcome_params: { "outcome" => "discharged" }, by: nurse)
    expect(result).to be_ok
    expect(nursing.reload.problem_items.map(&:code)).to contain_exactly("E119", "T90")

    described_class.generate(medical)
    described_class.generate(nursing)
    sent = ->(c) { ficha_of(LediOutboxEntry.find_by!(source_id: c.id)).atendimentosIndividuais.sole.problemasCondicoes }
    expect(sent.(nursing).map(&:cid10)).to all(be_nil)
    expect(sent.(nursing).map(&:ciap)).to eq([ "T90" ])
    expect(sent.(medical).map(&:cid10)).to eq([ "E119" ])
  end

  it "ficha em envio: tenta de novo depois (InFlight)" do
    consultation = finalized!
    described_class.generate(consultation)
    LediOutboxEntry.update_all(status: "sending")
    addendum!(consultation, "conducts" => [ 1, 9 ])
    expect { described_class.refresh!(consultation.reload) }.to raise_error(described_class::InFlight)
  end

  it "problema resolvido por adendo depois do atendimento: dataFimProblema não passa do dia da consulta" do
    consultation = finalized!
    described_class.generate(consultation)
    LediOutboxEntry.sole.reject!([ { "field" => "other", "code" => "unknown" } ])
    travel_to(3.days.from_now) do
      addendum!(consultation, "evaluated_problems" => [ { "problem_id" => PatientProblem.sole.id, "action" => "resolve" } ])
      described_class.refresh!(consultation.reload)
    end
    fresh = LediOutboxEntry.where(status: "pending").sole
    problem = ficha_of(fresh).atendimentosIndividuais.sole.problemasCondicoes.sole
    expect(problem.situacao).to eq(2)
    expect(problem.dataFimProblema).to eq((consultation.started_at.in_time_zone.to_date.in_time_zone.to_f * 1000).to_i)
  end
end
