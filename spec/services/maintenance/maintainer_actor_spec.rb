require "rails_helper"

# D6 da API de manutenção: o mantenedor pula a AUTORIZAÇÃO (papéis) e só ela.
# É o ator que diz "sim" à policy; as regras de domínio que olham o TIPO de
# ator (assinar, conceder papel privilegiado) continuam recusando.
RSpec.describe Maintenance::MaintainerActor do
  let(:maintainer) do
    Maintainer.create!(email_address: "ma-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let(:actor) { described_class.new(maintainer) }

  it "answers yes to every role a policy asks" do
    %i[protocol_author protocol_publisher protocol_reviewer municipal_admin viewer].each do |role|
      expect(actor.has_role?(role)).to be(true)
    end
  end

  it "identifies itself as a maintainer, by the maintainer's id" do
    expect(actor.id).to eq(maintainer.id)
    expect(actor.actor_kind).to eq("maintainer")
  end

  it "passes ProtocolPolicy without any membership in the city" do
    policy = ProtocolPolicy.new(actor, ProtocolDefinition.new)

    expect(policy.author?).to be(true)
    expect(policy.publish?).to be(true)
    expect(policy.activate?).to be(true)
  end

  it "has a user counterpart that says it is a user" do
    expect(User.new.actor_kind).to eq("user")
  end
end
