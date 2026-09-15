require "rails_helper"

RSpec.describe PurgeOperatorCitySessionsJob, type: :job do
  before { Current.city = TEST_CITY_A }

  # EachCityJob está prepended: o corpo roda direto na conexão que o harness abriu,
  # como em purge_domain_events_job_spec.rb.
  def call_body
    described_class.instance_method(:perform).super_method.bind_call(described_class.new)
  end

  it "deletes operator grant sessions past their TTL and never touches user sessions" do
    user = User.create!(email_address: "u-#{SecureRandom.hex(3)}@cidade.gov.br", password: "secret123")
    old_user_session = user.sessions.create!(created_at: 30.days.ago)
    expired = Session.create!(operator_id: SecureRandom.uuid, created_at: (Session::OPERATOR_GRANT_TTL + 1.minute).ago)
    live    = Session.create!(operator_id: SecureRandom.uuid)

    call_body

    expect(Session.where(id: [ old_user_session, expired, live ].map(&:id)).pluck(:id))
      .to contain_exactly(old_user_session.id, live.id)
  end

  it "runs in every active city" do
    expect(described_class.ancestors.first).to eq(EachCityJob)
  end
end
