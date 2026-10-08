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
