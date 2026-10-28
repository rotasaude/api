require "rails_helper"

# Módulo 25, Task 13 (ADR 0043): resumo diário das vencidas, só contagens.
RSpec.describe Surveillance::OverdueJob do
  include ActiveJob::TestHelper

  before { surveillance_city! }
  after { Current.reset }

  let!(:officer) { surveillance_officer!("vig-diaria@cidade.gov.br") }

  def run! = described_class.perform_now
  def mail_jobs = enqueued_jobs.select { |j| j["job_class"] == "Surveillance::MailJob" }

  it "uma imediata vencida: enfileira o e-mail do dia; o e-mail diz 1" do
    n = notification!(patient: surveillance_patient!(1), disease_code: "sarampo", by: officer)
    n.update_columns(due_at: 1.hour.ago)
    clear_enqueued_jobs

    run!

    assert_enqueued_with(job: Surveillance::MailJob,
                         args: [ { city_slug: Current.city.slug, kind: "overdue", ref: Time.zone.today.iso8601 } ])
    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs(only: Surveillance::MailJob)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq([ "vig-diaria@cidade.gov.br" ])
    expect(mail.text_part.body.decoded).to include("Vencidas: 1", "Imediatas entre elas: 1")
  end

  it "nenhuma vencida (no prazo, ou já em investigação): nada" do
    notification!(patient: surveillance_patient!(2), disease_code: "sarampo", by: officer) # no prazo
    n = notification!(patient: surveillance_patient!(3), disease_code: "dengue", by: officer)
    n.update_columns(status: "investigating", due_at: 1.day.ago) # investigação começou: não atrasa
    clear_enqueued_jobs

    run!

    expect(mail_jobs).to be_empty
  end

  it "com o interruptor desligado: nada" do
    n = notification!(patient: surveillance_patient!(4), disease_code: "sarampo", by: officer)
    n.update_columns(due_at: 1.hour.ago)
    clear_enqueued_jobs
    Platform::Features.set!(city: Current.city, key: "surveillance", enabled: false, maintainer: ledi_maintainer!)

    run!

    expect(mail_jobs).to be_empty
  end

  it "está agendada às 7h15 de São Paulo na fila housekeeping" do
    task = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result, aliases: true).fetch("development")
    expect(task.fetch("surveillance_overdue")).to include("class" => "Surveillance::OverdueJob", "queue" => "housekeeping",
                                                          "schedule" => "every day at 7:15am America/Sao_Paulo")
  end
end
