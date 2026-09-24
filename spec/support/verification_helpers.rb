module VerificationHelpers
  def issue_code_for(citizen)
    Citizens::IssueVerificationCode.call(citizen: citizen).payload.fetch(:code)
  end
end

RSpec.configure { |c| c.include VerificationHelpers }
