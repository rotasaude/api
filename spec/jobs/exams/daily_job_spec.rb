require "rails_helper"

# Spec §5 "Alertas" (F-21.5): job diário por cidade; ciência vencida vai à
# fila da equipe uma vez só; órfãos de 24 h somem. Review Focus 5.
RSpec.describe Exams::DailyJob do
  include ActiveSupport::Testing::TimeHelpers

  let(:city_zone) { "America/Sao_Paulo" }
  # A cidade nasce com o fuso do exemplo (o fuso é imutável depois: trigger).
  before do
    unless city_zone == "America/Sao_Paulo"
      City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active", time_zone: city_zone,
                   database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key,
                   schema_version: CitySchema.expected_version.to_s)
    end
    exam_city!
  end
  # O arranjo roda no fuso da cidade; o job acha o dele sozinho
  # (CityConnection.with). Exemplos de outro fuso rodam o job SEM use_zone.
  around { |example| Time.use_zone(city_zone) { example.run } }

  let(:unit) { create_unit("UBS Prazo") }
  let(:doctor) { doctor!(unit) }
  let(:zone) { ActiveSupport::TimeZone[city_zone] }
  # Âncora relativa ao relógio (lida antes de qualquer travel_to), não a uma
  # data fixa do calendário.
  let(:anchor) { zone.now.change(hour: 23, min: 59) }

  def resulted_order(at:, priority: "routine", provider: nil)
    travel_to(at) do
      order = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor, priority: priority)
      ApplicationRecord.transaction do
        order.lock!
        %w[scheduled collected resulted].each do |kind|
          Exams::Transition.call(order: order, kind: kind, actor_user: doctor,
                                 changes: kind == "scheduled" && provider ? { exam_provider_id: provider.id } : {},
                                 event_payload: kind == "resulted" ? { source: "unit", critical: false } : {})
        end
      end
      order.reload
    end
  end

  # Não escala no dia do prazo; escala às 6h30 do dia seguinte, uma vez só,
  # mesmo rodando duas vezes — o job usa o stage_due_on gravado.
  def expect_escalation_day_after(order, days:)
    expect(order.stage_due_on).to eq(order.status_changed_at.in_time_zone(zone).to_date + days)
    due = order.stage_due_on.in_time_zone(zone)
    described_class.perform_now(now: due.change(hour: 23))
    expect(order.reload.escalated?).to be(false)
    described_class.perform_now(now: (due + 1.day).change(hour: 6, min: 30))
    described_class.perform_now(now: (due + 1.day).change(hour: 7))
    events = order.reload.events.where(kind: "escalated")
    expect(events.pluck(:escalation_reason)).to eq(%w[overdue])
    expect(events.first.actor_user_id).to be_nil
    expect(events.first.actor_provider_id).to be_nil
  end

  it "escala a ciência vencida no dia seguinte ao prazo, uma vez só, mesmo rodando duas vezes" do
    expect_escalation_day_after(resulted_order(at: anchor), days: 15)
  end

  it "urgente: o prazo de ciência cai de 15 para 8 dias e o job respeita o gravado" do
    expect_escalation_day_after(resulted_order(at: anchor, priority: "urgent"), days: 8)
  end

  it "prazo próprio do prestador para o exame vale no job" do
    item = exam_catalog_item!
    provider = exam_provider!
    ExamProviderItem.find_by!(exam_provider: provider, exam_catalog_item: item).update!(acknowledge_days: 5)
    expect_escalation_day_after(resulted_order(at: anchor, provider: provider), days: 5)
  end

  context "cidade em outro fuso (America/Manaus, UTC-4)" do
    let(:city_zone) { "America/Manaus" }

    it "conta o dia no fuso da cidade, não no de São Paulo nem no UTC" do
      order = resulted_order(at: zone.now.change(hour: 21, min: 30))
      due = order.stage_due_on.in_time_zone(zone)
      # 23h30 de Manaus do dia do prazo já é dia seguinte em UTC e em São Paulo.
      Time.use_zone("UTC") { described_class.perform_now(now: due.change(hour: 23, min: 30)) }
      expect(order.reload.escalated?).to be(false)
      Time.use_zone("UTC") { described_class.perform_now(now: (due + 1.day).change(hour: 0, min: 30)) }
      expect(order.reload.events.where(kind: "escalated").count).to eq(1)
    end
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
