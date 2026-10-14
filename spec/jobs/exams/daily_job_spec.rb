require "rails_helper"

# Spec §5 "Alertas" (F-21.5): job diário por cidade; ciência vencida vai à
# fila da equipe uma vez só; órfãos de 24 h somem. Review Focus 5.
RSpec.describe Exams::DailyJob do
  include ActiveSupport::Testing::TimeHelpers

  before { exam_city! }
  # O job roda no fuso da cidade (CityConnection.with); o arranjo também.
  around { |example| Time.use_zone("America/Sao_Paulo") { example.run } }

  let(:unit) { create_unit("UBS Prazo") }
  let(:doctor) { doctor!(unit) }
  let(:zone) { ActiveSupport::TimeZone["America/Sao_Paulo"] }
  # Âncora fixa: as datas do spec são relativas a ela, não ao calendário real.
  let(:anchor) { zone.local(2026, 10, 1, 23, 59) }

  def resulted_order(at:)
    travel_to(at) do
      order = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor)
      ApplicationRecord.transaction do
        order.lock!
        %w[scheduled collected resulted].each do |kind|
          Exams::Transition.call(order: order, kind: kind, actor_user: doctor, event_payload: kind == "resulted" ? { source: "unit", critical: false } : {})
        end
      end
      order.reload
    end
  end

  it "escala a ciência vencida no dia seguinte ao prazo, uma vez só, mesmo rodando duas vezes" do
    order = resulted_order(at: anchor)
    expect(order.stage_due_on).to eq(anchor.to_date + 15)
    due = order.stage_due_on.in_time_zone(zone)
    described_class.perform_now(now: due.change(hour: 23))
    expect(order.reload.escalated?).to be(false)
    described_class.perform_now(now: (due + 1.day).change(hour: 6, min: 30))
    described_class.perform_now(now: (due + 1.day).change(hour: 7))
    events = order.reload.events.where(kind: "escalated")
    expect(events.pluck(:escalation_reason)).to eq(%w[overdue])
    expect(events.first.actor_user_id).to be_nil
  end

  it "apaga só os arquivos órfãos com mais de 24 h" do
    old = travel_to(25.hours.ago) { pdf_file!(user: doctor) }
    fresh = pdf_file!(user: doctor)
    used = travel_to(30.hours.ago) { pdf_file!(user: doctor) }.tap { |f| f.update!(consumed_at: Time.current) }
    described_class.perform_now
    expect(ExamFile.where(id: [ old.id, fresh.id, used.id ]).pluck(:id)).to contain_exactly(fresh.id, used.id)
  end

  it "com exam_tracking desligado não escala (mas purga)" do
    order = resulted_order(at: 40.days.ago)
    old = travel_to(25.hours.ago) { pdf_file!(user: doctor) }
    Platform::Features.set!(city: Current.city, key: "exam_tracking", enabled: false, maintainer: ledi_maintainer!)
    described_class.perform_now
    expect(order.reload.escalated?).to be(false)
    expect(ExamFile.where(id: old.id)).to be_empty
  end

  it "agendado todo dia às 6h30 em cada cidade (config/recurring.yml)" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "exams_daily")
    expect(entry).to eq("class" => "Exams::DailyJob", "queue" => "housekeeping", "schedule" => "every day at 6:30am America/Sao_Paulo")
    expect(described_class.ancestors).to include(EachCityJob)
  end
end
