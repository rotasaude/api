require "rails_helper"

# Módulo 31 (contrato P16): o job diário de revisão do PTS vencida. Por cidade
# (EachCityJob), só com `psychosocial_care` utilizável; um aviso
# (psychosocial_care_plan_alerts) e um evento por versão vencida, só com o id.
RSpec.describe Psychosocial::CarePlanReviewJob do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps) }
  let(:events) { DomainEvent.where(name: "psychosocial.care_plan_review_due") }

  def plan!(enrollment, version: 1, review_on:)
    PsychosocialCarePlan.create!(psychosocial_enrollment: enrollment, version: version, needs: "Necessidades do usuário", goals: [],
                                 intensity: "intensive", review_on: review_on, created_by_user: staff)
  end

  it "avisa uma vez por versão vencida, mesmo rodando duas vezes no dia, e nenhuma para a revisão em dia" do
    overdue = plan!(enrollment!(caps, reference: staff), review_on: Date.current - 1)
    plan!(enrollment!(caps, reference: staff), review_on: Date.current)
    plan!(enrollment!(caps, reference: staff), review_on: Date.current + 7)

    expect { described_class.perform_now; described_class.perform_now }.to change { events.count }.by(1)
    expect(events.last.payload).to eq("care_plan_id" => overdue.id)
    expect(PsychosocialCarePlanAlert.pluck(:psychosocial_care_plan_id)).to eq([ overdue.id ])
  end

  it "só a última versão vale, e a matrícula encerrada não é avisada" do
    renewed = enrollment!(caps, reference: staff)
    plan!(renewed, version: 1, review_on: Date.current - 10)
    plan!(renewed, version: 2, review_on: Date.current + 30)
    closed = enrollment!(caps, reference: staff)
    plan!(closed, review_on: Date.current - 4)
    closed.update!(closed_on: Date.current, destination: "01", closed_by_user: staff)

    expect { described_class.perform_now }.not_to(change { [ events.count, PsychosocialCarePlanAlert.count ] })
  end

  it "uma versão nova que vence depois recebe o seu próprio aviso" do
    enrollment = enrollment!(caps, reference: staff)
    first = plan!(enrollment, review_on: Date.current - 1)
    described_class.perform_now
    second = plan!(enrollment, version: 2, review_on: Date.current + 3)
    described_class.perform_now
    expect(events.count).to eq(1)

    travel_to(5.days.from_now) { described_class.perform_now }
    expect(events.map { |e| e.payload["care_plan_id"] }).to contain_exactly(first.id, second.id)
  end

  it "com o interruptor desligado, nada" do
    plan!(enrollment!(caps, reference: staff), review_on: Date.current - 1)
    Platform::Features.set!(city: city, key: "psychosocial_care", enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!

    expect { described_class.perform_now }.not_to(change { [ events.count, PsychosocialCarePlanAlert.count ] })
  end

  it "o evento e o log não levam dado do paciente" do
    enrollment = enrollment!(caps, reference: staff)
    plan!(enrollment, review_on: Date.current - 1)
    log = capture_log { described_class.perform_now }
    expect(log).not_to include(enrollment.patient.display_name)
    expect(events.last.payload.keys).to eq([ "care_plan_id" ])
  end

  it "está agendado todo dia às 7h no fuso de São Paulo, na fila housekeeping" do
    task = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml")).fetch("default").fetch("psychosocial_care_plan_review")
    expect(task).to include("class" => "Psychosocial::CarePlanReviewJob", "queue" => "housekeeping",
                            "schedule" => "every day at 7am America/Sao_Paulo")
  end
end
