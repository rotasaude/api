require "rails_helper"

# ADR 0035 (spec §4): cada fornecedor devolve as entradas da pessoa, depois
# do cursor, na ordem occurred_at DESC, id ASC, com a visão do profissional
# e a do cidadão. Nenhum texto livre na visão do cidadão.
RSpec.describe "Fornecedores administrativos da linha do tempo" do
  include ActiveSupport::Testing::TimeHelpers
  before do
    timeline_city!(record_mode: "integrated", clinical_record: false)
    ciap2_release!
    acolhimento!
    ensure_appointment_types!
  end

  let(:unit) { create_unit("UBS Vila Nova") }
  let(:nurse) { screener!(unit) }
  let(:citizen) { verified_citizen!(51) }
  let(:person) { Timeline::Person.for_cpf(citizen.cpf) }
  let(:stranger) { verified_citizen!(52) }

  def entries(source, **opts) = source.entries(person: person, before: nil, limit: 50, from: nil, to: nil, **opts)

  it "triage: sem as em andamento, com protocolo e prioridade; nunca a de outra pessoa" do
    triage = completed_web_triage_for(citizen)
    completed_web_triage_for(stranger)
    entry = entries(Timeline::Sources::TriageSource).sole
    expect(entry.to_h.slice(:kind, :source_id, :status)).to eq(kind: "triage", source_id: triage.id, status: triage.status)
    expect(entry.occurred_at).to eq(triage.created_at)
    expect(entry.detail_ref).to eq(type: "triage", id: triage.id)
    expect(entry.citizen[:title]).to start_with("Triagem")
  end

  it "attendance: unidade, chegada e desfecho em termos simples para o cidadão" do
    attendance = walk_in_attendance!(unit, citizen: citizen)
    # O gatilho do banco exige waiting -> in_care -> closed (ajuste ao real, mesma asserção).
    attendance.update_columns(status: "in_care", called_by_user_id: nurse.id, called_at: Time.current)
    attendance.update_columns(status: "closed", outcome: "discharged", closed_by_user_id: nurse.id, closed_at: Time.current)
    entry = entries(Timeline::Sources::AttendanceSource).sole
    expect(entry.unit).to eq(id: unit.id, name: "UBS Vila Nova")
    expect(entry.occurred_at).to eq(attendance.checked_in_at)
    expect(entry.summary).to eq("Alta")
    expect(entry.citizen).to include(title: "Atendimento na UBS Vila Nova", summary: "Atendimento concluído")
  end

  it "screening: só concluída; profissional vê cor, destino e CIAP-2; cidadão vê 'acolhimento realizado'" do
    attendance = walk_in_attendance!(unit, citizen: citizen)
    started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    Screenings::Complete.call(screening: started, revision_params: revision_params, destination: "oriented",
                              destination_params: { "orientation_note" => "repouso e hidratação" }, by: nurse)
    entry = entries(Timeline::Sources::ScreeningSource).sole
    expect(entry.title).to eq("Escuta inicial — verde")
    expect(entry.summary).to include("Orientado", "K86 Hipertensão sem complicações")
    expect(entry.professional).to eq(name: nurse.professional.professional_name, cbo_code: "223505")
    expect(entry.citizen).to eq(title: "Acolhimento realizado", summary: nil, status: nil,
                                professional_name: nurse.professional.professional_name)
    expect(entry.to_h.to_s).not_to include("repouso e hidratação")
  end

  it "appointment: tipo e situação; o horário movido some" do
    request = triage_request!(citizen, unit: unit)
    link = doctor_link!(unit)
    shift = shift!(link, starts_at: 2.days.from_now.change(hour: 8))
    appointment = appointment_row!(request, shift, starts_at: shift.starts_at)
    entry = entries(Timeline::Sources::AppointmentSource).sole
    expect([ entry.source_id, entry.occurred_at, entry.status ]).to eq([ appointment.id, appointment.scheduled_at, "confirmed" ])
    expect(entry.title).to start_with("Agendamento — ")
    expect(entry.detail_ref).to eq(type: "appointment_request", id: request.id)
    appointment.update_columns(status: "moved", ended_at: Time.current)
    expect(entries(Timeline::Sources::AppointmentSource)).to be_empty
  end

  it "janela: período, cursor estritamente depois e desempate por id" do
    at = Time.zone.parse("2026-09-01 10:00")
    rows = Array.new(3) { walk_in_attendance!(unit, citizen: citizen, checked_in_at: at) }
    older = walk_in_attendance!(unit, citizen: citizen, checked_in_at: at - 1.day)
    all = entries(Timeline::Sources::AttendanceSource)
    expect(all.map(&:source_id)).to eq(rows.map(&:id).sort + [ older.id ])
    cursor = Timeline::Cursor.decode(Timeline::Cursor.encode(all.first))
    after = Timeline::Sources::AttendanceSource.entries(person: person, before: cursor, limit: 50, from: nil, to: nil)
    expect(after.map(&:source_id)).to eq(all.drop(1).map(&:source_id))
    ranged = Timeline::Sources::AttendanceSource.entries(person: person, before: nil, limit: 50,
                                                         from: (at - 1.hour), to: (at + 1.hour))
    expect(ranged.map(&:source_id)).to match_array(rows.map(&:id))
    earlier_kind = Timeline::Cursor.new(at: at, kind: "appointment", id: rows.first.id)
    expect(Timeline::Sources::AttendanceSource.entries(person: person, before: earlier_kind, limit: 50, from: nil, to: nil).size).to eq(4)
    later_kind = Timeline::Cursor.new(at: at, kind: "campaign", id: rows.first.id)
    expect(Timeline::Sources::AttendanceSource.entries(person: person, before: later_kind, limit: 50, from: nil, to: nil).map(&:source_id))
      .to eq([ older.id ])
  end
end
