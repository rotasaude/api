# spec/commands/screenings/complete_spec.rb
require "rails_helper"

# ADR 0030 (spec §4): cada destino e o desfecho que fecha o atendimento.
RSpec.describe Screenings::Complete do
  before { Current.city = TEST_CITY_A; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }
  let(:attendance) { walk_in_attendance!(unit, citizen: screening_citizen!(1)) }
  let(:screening) { Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening] }

  def complete(destination, params = {}, **revision)
    described_class.call(screening: screening, revision_params: revision_params(**revision), destination: destination,
                         destination_params: params, by: nurse)
  end

  it "same_day: escuta concluída, atendimento segue aguardando; evento só com ids" do
    result = complete("same_day", final_color: "yellow")
    expect(result).to be_ok
    screening.reload
    expect(screening).to have_attributes(status: "completed", destination: "same_day")
    expect(screening.current_revision).to have_attributes(final_color: "yellow", by_user_id: nurse.id, ciap2_code: "K86")
    expect(attendance.reload.status).to eq("waiting")
    expect(DomainEvent.where(name: "screening.completed").sole.payload)
      .to eq("screening_id" => screening.id, "attendance_id" => attendance.id, "destination" => "same_day",
             "final_color" => "yellow")
  end

  it "schedule: pedido do módulo 17 com origem na escuta, prazo pela cor; atendimento fecha scheduled_from_screening" do
    type = appointment_type!
    result = complete("schedule", { "schedule" => { "appointment_type_key" => type.key, "priority" => "routine" } },
                      final_color: "yellow")
    expect(result).to be_ok
    request = result.payload[:appointment_request]
    expect(request).to have_attributes(kind: "screening", origin_screening_id: screening.id,
                                       origin_attendance_id: attendance.id, target_unit_id: unit.id,
                                       appointment_type_key: type.key, priority: "routine",
                                       due_on: Time.zone.today + 7, status: "open")
    expect(screening.reload.appointment_request_id).to eq(request.id)
    expect(attendance.reload).to have_attributes(status: "closed", outcome: "scheduled_from_screening",
                                                 closed_by_user_id: nurse.id)
    expect(DomainEvent.where(name: "appointment_request.created").sole.payload).to include("kind" => "screening")
  end

  it "schedule: prazo dado vence o padrão; red sem prazo, tipo inexistente ou prioridade inválida → invalid_schedule" do
    type = appointment_type!
    expect(complete("schedule", { "schedule" => { "appointment_type_key" => type.key, "priority" => "routine" } },
                    final_color: "red").reason).to eq(:invalid_schedule)
    expect(complete("schedule", { "schedule" => { "appointment_type_key" => "fantasma", "priority" => "routine" } },
                    final_color: "green").reason).to eq(:invalid_schedule)
    expect(complete("schedule", { "schedule" => { "appointment_type_key" => type.key, "priority" => "urgente" } },
                    final_color: "green").reason).to eq(:invalid_schedule)
    expect(complete("schedule", { "schedule" => { "appointment_type_key" => type.key, "priority" => "priority",
                                                  "due_in_days" => 3 } }, final_color: "red")).to be_ok
    expect(screening.reload.appointment_request.due_on).to eq(Time.zone.today + 3)
  end

  it "oriented exige orientação (até 500) e fecha oriented" do
    expect(complete("oriented").reason).to eq(:orientation_required)
    expect(complete("oriented", { "orientation_note" => "x" * 501 }).reason).to eq(:note_too_long)
    expect(complete("oriented", { "orientation_note" => "Hidratação, retorno se piorar" })).to be_ok
    expect(attendance.reload.outcome).to eq("oriented")
    expect(screening.reload.orientation_note).to eq("Hidratação, retorno se piorar")
  end

  it "referred: unidade gera pedido como hoje; só descrição fecha sem pedido; nada → referral_required" do
    expect(complete("referred").reason).to eq(:referral_required)
    expect(complete("referred", { "referral" => { "referral_unit_id" => "nao-e-uuid" } }).reason).to eq(:invalid_unit)
    upa = create_unit("UPA Norte", kind: "upa")
    upa.update!(active: false)
    expect(complete("referred", { "referral" => { "referral_unit_id" => upa.id } }).reason).to eq(:invalid_unit)
    upa.update!(active: true)
    result = complete("referred", { "referral" => { "referral_unit_id" => upa.id } })
    expect(result).to be_ok
    expect(attendance.reload).to have_attributes(outcome: "referred", referral_unit_id: upa.id)
    expect(result.payload[:appointment_request]).to have_attributes(kind: "referral", target_unit_id: upa.id)
  end

  it "referred para uuid de unidade que não existe → invalid_unit, nada gravado (contratos §9)" do
    result = complete("referred", { "referral" => { "referral_unit_id" => SecureRandom.uuid } })
    expect(result.reason).to eq(:invalid_unit)
    expect(screening.reload).to have_attributes(status: "in_progress", current_revision_id: nil)
    expect(attendance.reload.status).to eq("waiting")
  end

  it "note_too_long diz o campo: queixa e orientação (contratos §9)" do
    long = complete("same_day", complaint_note: "x" * 501)
    expect([ long.reason, long.details[:field] ]).to eq([ :note_too_long, "complaint_note" ])
    long = complete("oriented", { "orientation_note" => "x" * 501 })
    expect([ long.reason, long.details[:field] ]).to eq([ :note_too_long, "orientation_note" ])
  end

  it "schedule: tipo inativo → invalid_schedule" do
    type = appointment_type!
    type.update!(active: false)
    expect(complete("schedule", { "schedule" => { "appointment_type_key" => type.key, "priority" => "routine" } },
                    final_color: "green").reason).to eq(:invalid_schedule)
  end

  it "autorização: quem não tem vínculo na unidade não conclui" do
    screening
    outsider = screener!(create_unit("UBS Outra"))
    result = described_class.call(screening: screening, revision_params: revision_params, destination: "same_day",
                                  destination_params: {}, by: outsider)
    expect(result.reason).to eq(:missing_link)
    expect(screening.reload.status).to eq("in_progress")
  end

  it "referred só com descrição fecha sem pedido" do
    result = complete("referred", { "referral" => { "referral_note" => "CAPS" } })
    expect(result).to be_ok
    expect(result.payload[:appointment_request]).to be_nil
    expect(attendance.reload).to have_attributes(outcome: "referred", referral_note: "CAPS")
  end

  it "destino inválido, escuta que não está em curso e atendimento que não aguarda" do
    expect(complete("agora").reason).to eq(:invalid_destination)
    Screenings::Abandon.call(screening: screening, by: nurse)
    expect(complete("same_day").reason).to eq(:not_in_progress)
  end

  it "atendimento chamado por fora (sem passar pelo Call) → attendance_not_waiting" do
    screening
    attendance.update!(status: "in_care", called_by_user: nurse, called_at: Time.current)
    expect(complete("same_day").reason).to eq(:attendance_not_waiting)
  end

  it "conclui com o vínculo e CBO de quem conclui" do
    screening
    tech = screener!(unit, cbo: "322205")
    result = described_class.call(screening: screening, revision_params: revision_params, destination: "same_day",
                                  destination_params: {}, by: tech)
    expect(result).to be_ok
    expect(screening.reload).to have_attributes(cbo_code: "322205", started_by_user_id: nurse.id)
  end
end
