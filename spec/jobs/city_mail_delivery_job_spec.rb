require "rails_helper"

# I1 (hardening review): ActiveJob's LogSubscriber logs `with arguments: ...`
# at info level for every job whose log_arguments? is true (the default), and
# it does NOT run Rails' filter_parameters over that line. CityMailDeliveryJob
# wraps ActionMailer::MailDeliveryJob (deliver_later), so its arguments carry
# the mailer method's raw params — for InvitationMailer, the accept_url (with
# the token) and the recipient e-mail. Left at the default, any process that
# enqueues an invitation mail (the city:invite_admin rake task, the worker)
# prints the token straight to its log/STDOUT.
RSpec.describe CityMailDeliveryJob do
  it "does not log the mailer arguments (token, e-mail) when enqueuing an invitation" do
    log_output = StringIO.new
    original_logger = ActiveJob::Base.logger
    ActiveJob::Base.logger = ActiveSupport::Logger.new(log_output)

    begin
      on_platform_queue do
        InvitationMailer.invite(
          email_address: "prefeita@cidade.gov.br",
          accept_url: "https://dashboard.example/invite/s3cr3t-token-abc123"
        ).deliver_later
      end
    ensure
      ActiveJob::Base.logger = original_logger
    end

    logged = log_output.string
    expect(logged).not_to include("s3cr3t-token-abc123")
    expect(logged).not_to include("prefeita@cidade.gov.br")
  end
end
