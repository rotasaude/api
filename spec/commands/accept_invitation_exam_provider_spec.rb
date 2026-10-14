require "rails_helper"

# ADR 0036: o convite do prestador liga o usuário novo ao prestador, numa
# transação só com o usuário e o papel.
RSpec.describe AcceptInvitation do
  before { exam_city! }

  it "cria ExamProviderUser junto com o papel exam_provider" do
    provider = exam_provider!
    admin = municipal_admin!
    invitation = Exams::InviteProviderUser.call(provider: provider, email: "lab@central.com.br", invited_by: admin)
                                          .payload.fetch(:invitation)
    result = described_class.call(token: invitation.token, password: "senha-muito-segura-1")
    expect(result).to be_ok
    user = result.payload[:user]
    expect(user.has_role?("exam_provider")).to be(true)
    expect(ExamProviderUser.find_by(user: user).exam_provider).to eq(provider)
  end
end
