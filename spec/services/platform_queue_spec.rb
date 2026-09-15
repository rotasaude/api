require "rails_helper"

# Plano 5: a fila de plataforma mora no banco de plataforma, que nunca guarda dado
# de cidadão. Só jobs de ciclo de vida entram nela; job de cidade fora de cidade
# levanta em vez de cair ali.
RSpec.describe PlatformQueue do
  include ActiveJob::TestHelper

  let(:city_job) { stub_const("PlatformQueueCityProbeJob", Class.new(ApplicationJob) { def perform; end }) }
  let(:reset_url) { "http://testcitya.localhost:5175/dashboard/?reset=tok" }
  let(:accept_url) { "http://testcitya.localhost:5175/dashboard/?invite=tok" }

  after { CityWorkers::Context.city_slug = nil }

  it "accepts a city job inside a city and refuses it on the platform queue" do
    expect { city_job.perform_later }.to have_enqueued_job(city_job)
    expect { on_platform_queue { city_job.perform_later } }
      .to raise_error(PlatformQueue::Misplaced, /PlatformQueueCityProbeJob/)
  end

  it "accepts a platform job on the platform queue and refuses it inside a city" do
    expect { on_platform_queue { PurgePlatformAccessJob.perform_later } }.to have_enqueued_job(PurgePlatformAccessJob)
    expect { PurgePlatformAccessJob.perform_later }.to raise_error(PlatformQueue::Misplaced, /PurgePlatformAccessJob/)
  end

  it "accepts only the invitation mailer on the platform queue" do
    expect { on_platform_queue { InvitationMailer.invite(email_address: "a@cidade.gov.br", accept_url: accept_url).deliver_later } }
      .to have_enqueued_job(CityMailDeliveryJob)
    expect { on_platform_queue { PasswordMailer.reset(email_address: "a@cidade.gov.br", reset_url: reset_url).deliver_later } }
      .to raise_error(PlatformQueue::Misplaced, /PasswordMailer/)
    expect { PasswordMailer.reset(email_address: "a@cidade.gov.br", reset_url: reset_url).deliver_later }
      .to have_enqueued_job(CityMailDeliveryJob)
  end

  it "treats the default shard as the city's queue inside a city worker process" do
    CityWorkers::Context.city_slug = "curitiba"

    expect(described_class.platform_target?).to be(false)
    expect { on_platform_queue { city_job.perform_later } }.to have_enqueued_job(city_job)
  end

  it "lets Solid Queue's recurring command job into any queue" do
    job = SolidQueue::RecurringJob.new("SolidQueue::Job.clear_finished_in_batches")

    expect { described_class.check!(job) }.not_to raise_error
    expect { on_platform_queue { described_class.check!(job) } }.not_to raise_error
  end
end
