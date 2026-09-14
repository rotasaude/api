require "rails_helper"

# Sessão da cidade: exatamente UM ator — usuário da cidade ou operador da
# plataforma (entrada por grant, Plano 3B). A regra vale no modelo e no banco.
RSpec.describe Session do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { User.create!(email_address: "s-#{SecureRandom.hex(3)}@x.com", password: "secret123") }
  let(:operator) do
    Operator.create!(email_address: "op-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end

  it "is valid with a user only, or with an operator only" do
    expect(described_class.new(user: user)).to be_valid
    expect(described_class.new(operator_id: operator.id)).to be_valid
  end

  it "is invalid with neither actor or with both" do
    expect(described_class.new).not_to be_valid
    expect(described_class.new(user: user, operator_id: operator.id)).not_to be_valid
  end

  it "the city database refuses a session with neither actor or with both, even skipping validation" do
    expect { described_class.new.save!(validate: false) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_sessions_exactly_one_actor/)
    expect { described_class.new(user: user, operator_id: operator.id).save!(validate: false) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_sessions_exactly_one_actor/)
  end

  describe "#usable?" do
    it "a user session is always usable" do
      expect(described_class.create!(user: user)).to be_usable
    end

    it "an operator session is usable for one hour while the operator is active" do
      session = described_class.create!(operator_id: operator.id)
      expect(session).to be_operator_grant
      expect(session.operator).to eq(operator)
      expect(session).to be_usable

      travel 59.minutes do
        expect(session).to be_usable
      end
      travel 61.minutes do
        expect(session).not_to be_usable
      end
    end

    it "an operator session stops being usable once the operator is deactivated" do
      session = described_class.create!(operator_id: operator.id)
      operator.update!(deactivated_at: Time.current)

      expect(session).not_to be_usable
    end
  end
end
