require "rails_helper"

# Módulo 25, Task 13 (ADR 0043; K7): lembrete de segunda-feira para as unidades
# notificadoras sem negativa nem caso na semana epidemiológica anterior.
RSpec.describe Surveillance::NegativesReminderJob do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  before { surveillance_city! }
  after { Current.reset }

  let!(:officer) { surveillance_officer!("vig-semanal@cidade.gov.br") }
  # Segunda 2026-10-19 (SE 42, de 18 a 24/10); a semana anterior é a SE 41 (11 a 17/10).
  let(:monday) { Time.zone.local(2026, 10, 19, 7, 30) }
  let(:week) { Surveillance::EpiWeek.new(year: 2026, week: 41) }

  def mail_jobs = enqueued_jobs.select { |j| j["job_class"] == "Surveillance::MailJob" }

  def run_on_monday!
    travel_to(monday) do
      clear_enqueued_jobs
      described_class.perform_now
    end
  end

  def pending_names = described_class.pending_units(week).map(&:name)

  it "a unidade notificadora sem nada na semana anterior aparece; o e-mail a nomeia" do
    create_unit("UBS Esquecida")
    ActionMailer::Base.deliveries.clear

    travel_to(monday) do
      clear_enqueued_jobs
      described_class.perform_now
      assert_enqueued_with(job: Surveillance::MailJob,
                           args: [ { city_slug: Current.city.slug, kind: "negatives", ref: "2026-41" } ])
      perform_enqueued_jobs(only: Surveillance::MailJob)
    end

    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq([ "vig-semanal@cidade.gov.br" ])
    expect(mail.text_part.body.decoded).to include("2026-41", "UBS Esquecida")
  end

  it "com negativa da semana, com caso na semana, ou não notificadora: não aparece" do
    reported = create_unit("UBS Negativou")
    cased = create_unit("UBS Com Caso")
    create_unit("Hospital Fora", kind: "hospital") # nasce notifying: false
    silent = create_unit("UBS Silenciosa")
    inactive = create_unit("UBS Inativa", active: false)
    WeeklyNegativeReport.create!(health_unit: reported, week: "2026-41", recorded_by_user: officer)
    notification!(patient: surveillance_patient!(1), unit: cased, suspected_at: Time.zone.local(2026, 10, 14, 10), status: "notified", by: officer)

    expect(pending_names).to eq([ "UBS Silenciosa" ])
    expect(pending_names).not_to include(inactive.name, "UBS Negativou", "UBS Com Caso", "Hospital Fora")
    expect(silent).to be_persisted
  end

  it "negativa de outra semana não vale; possível na semana não tira a pendência" do
    unit = create_unit("UBS Só Possível")
    WeeklyNegativeReport.create!(health_unit: unit, week: "2026-40", recorded_by_user: officer)
    notification!(patient: surveillance_patient!(2), unit: unit, origin: "safety_net", suspected_at: Time.zone.local(2026, 10, 14, 10))

    expect(pending_names).to eq([ "UBS Só Possível" ])
  end

  it "ninguém pendente: nada é enfileirado" do
    HealthUnit.update_all(notifying: false)

    run_on_monday!

    expect(mail_jobs).to be_empty
  end

  it "interruptor desligado: nada" do
    create_unit("UBS Esquecida")
    Platform::Features.set!(city: Current.city, key: "surveillance", enabled: false, maintainer: ledi_maintainer!)

    run_on_monday!

    expect(mail_jobs).to be_empty
  end

  it "está agendada às segundas 7h30 de São Paulo na fila housekeeping" do
    task = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result, aliases: true).fetch("development")
    expect(task.fetch("surveillance_negatives")).to include("class" => "Surveillance::NegativesReminderJob", "queue" => "housekeeping",
                                                            "schedule" => "every monday at 7:30am America/Sao_Paulo")
  end
end
